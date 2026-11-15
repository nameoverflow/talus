use crate::config::{expand_tilde, StatusCommand};
use std::collections::HashMap;
use std::io::Read;
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

struct CommandSlot {
    next_run: Option<Instant>,
    text: String,
    running_pid: Option<u32>,
}

pub struct StatusCommandsEngine {
    slots: Arc<Mutex<HashMap<usize, CommandSlot>>>,
    stopped: Arc<Mutex<bool>>,
    state_file: Option<String>,
    state_json: Arc<Mutex<Option<String>>>,
    on_change_callback: Arc<Mutex<Option<Box<dyn Fn() + Send + Sync>>>>,
}

impl StatusCommandsEngine {
    pub fn new(
        state_file: Option<String>,
        on_change: Option<Box<dyn Fn() + Send + Sync>>,
    ) -> Self {
        Self {
            slots: Arc::new(Mutex::new(HashMap::new())),
            stopped: Arc::new(Mutex::new(false)),
            state_file,
            state_json: Arc::new(Mutex::new(None)),
            on_change_callback: Arc::new(Mutex::new(on_change)),
        }
    }

    pub fn set_state_json(&self, json: Option<String>) {
        if let Ok(mut guard) = self.state_json.lock() {
            *guard = json;
        }
    }

    pub fn get_state_json(&self) -> Option<String> {
        self.state_json.lock().ok().and_then(|g| g.clone())
    }

    pub fn value(&self, index: usize, block: &StatusCommand) -> String {
        let is_stopped = *self.stopped.lock().unwrap();
        let mut slots = self.slots.lock().unwrap();
        let slot = slots.entry(index).or_insert(CommandSlot {
            next_run: None,
            text: String::new(),
            running_pid: None,
        });
        if is_stopped {
            return slot.text.clone();
        }
        let now = Instant::now();
        let should_start = slot.running_pid.is_none()
            && slot.next_run.map(|next| now >= next).unwrap_or(true);
        let current_text = slot.text.clone();
        if should_start {
            let interval_secs = block.interval.unwrap_or(10.0).max(0.1);
            slot.next_run = Some(now + Duration::from_secs_f64(interval_secs));
            self.start_locked(index, block, slot);
        }
        current_text
    }

    fn start_locked(&self, index: usize, block: &StatusCommand, slot: &mut CommandSlot) {
        let mut cmd = Command::new(&block.executable);
        if let Some(ref args) = block.arguments {
            cmd.args(args);
        }
        if let Some(ref sf) = self.state_file {
            if !sf.is_empty() {
                cmd.env("TALUS_STATUS_FILE", expand_tilde(sf, None));
            }
        }
        if let Some(json) = self.get_state_json() {
            cmd.env("TALUS_STATUS_JSON", json);
        }
        cmd.stdin(Stdio::null());
        cmd.stdout(Stdio::piped());
        cmd.stderr(Stdio::null());

        let mut child = match cmd.spawn() {
            Ok(c) => c,
            Err(_) => {
                slot.running_pid = None;
                if !slot.text.is_empty() {
                    slot.text.clear();
                    Self::notify(&self.on_change_callback);
                }
                return;
            }
        };

        let pid = child.id();
        slot.running_pid = Some(pid);
        let stdout = child.stdout.take();
        let timeout_secs = block.timeout.unwrap_or(2.0).max(0.05);
        let interval_secs = block.interval.unwrap_or(10.0).max(0.1);

        let captured = Arc::new(Mutex::new(Vec::<u8>::new()));
        if let Some(mut reader) = stdout {
            let cap_clone = Arc::clone(&captured);
            std::thread::spawn(move || {
                let mut buf = [0u8; 1024];
                loop {
                    match reader.read(&mut buf) {
                        Ok(0) | Err(_) => break,
                        Ok(n) => {
                            let mut bytes = cap_clone.lock().unwrap();
                            let rem = 4096usize.saturating_sub(bytes.len());
                            if rem > 0 {
                                let take = n.min(rem);
                                bytes.extend_from_slice(&buf[..take]);
                            } else {
                                // Drain remaining stdout without storing so child doesn't SIGPIPE/block
                            }
                        }
                    }
                }
            });
        }

        let slots_ref = Arc::clone(&self.slots);
        let stopped_ref = Arc::clone(&self.stopped);
        let cb_ref = Arc::clone(&self.on_change_callback);

        std::thread::spawn(move || {
            let start_time = Instant::now();
            let timeout_dur = Duration::from_secs_f64(timeout_secs);
            let mut timed_out = false;
            let exit_status = loop {
                match child.try_wait() {
                    Ok(Some(status)) => break Some(status),
                    Ok(None) => {
                        if *stopped_ref.lock().unwrap() {
                            unsafe {
                                libc::kill(pid as i32, libc::SIGKILL);
                            }
                            let _ = child.wait();
                            return;
                        }
                        let elapsed = start_time.elapsed();
                        if elapsed >= timeout_dur {
                            if !timed_out {
                                timed_out = true;
                                unsafe {
                                    libc::kill(pid as i32, libc::SIGTERM);
                                }
                            } else if elapsed >= timeout_dur + Duration::from_millis(500) {
                                unsafe {
                                    libc::kill(pid as i32, libc::SIGKILL);
                                }
                                let _ = child.wait();
                                break None;
                            }
                        }
                        std::thread::sleep(Duration::from_millis(15));
                    }
                    Err(_) => break None,
                }
            };

            // Give stdout reader thread a brief moment to flush final bytes
            std::thread::sleep(Duration::from_millis(20));

            let succeeded = !timed_out
                && exit_status
                    .map(|s| s.success())
                    .unwrap_or(false);
            let new_text = if succeeded {
                let raw = captured.lock().unwrap();
                String::from_utf8_lossy(&raw)
                    .trim_matches(|c| c == '\r' || c == '\n')
                    .to_string()
            } else {
                String::new()
            };

            let mut changed = false;
            let mut wake_delay: Option<Duration> = None;
            if let Ok(mut slots) = slots_ref.lock() {
                if let Some(slot) = slots.get_mut(&index) {
                    if slot.running_pid == Some(pid) {
                        slot.running_pid = None;
                        if slot.text != new_text {
                            slot.text = new_text;
                            changed = true;
                        }
                        if let Some(next) = slot.next_run {
                            let now = Instant::now();
                            wake_delay = Some(if next > now {
                                next - now
                            } else {
                                Duration::from_millis(10)
                            });
                        } else {
                            wake_delay = Some(Duration::from_secs_f64(interval_secs));
                        }
                    }
                }
            }

            if changed && !*stopped_ref.lock().unwrap() {
                Self::notify(&cb_ref);
            }

            if let Some(delay) = wake_delay {
                let slots_wake = Arc::clone(&slots_ref);
                let stopped_wake = Arc::clone(&stopped_ref);
                let cb_wake = Arc::clone(&cb_ref);
                std::thread::spawn(move || {
                    std::thread::sleep(delay);
                    if *stopped_wake.lock().unwrap() {
                        return;
                    }
                    let is_idle = slots_wake
                        .lock()
                        .ok()
                        .and_then(|s| s.get(&index).map(|slot| slot.running_pid.is_none()))
                        .unwrap_or(false);
                    if is_idle {
                        Self::notify(&cb_wake);
                    }
                });
            }
        });
    }

    fn notify(cb_ref: &Arc<Mutex<Option<Box<dyn Fn() + Send + Sync>>>>) {
        if let Ok(guard) = cb_ref.lock() {
            if let Some(ref cb) = *guard {
                cb();
            }
        }
    }

    pub fn state_changed(&self, commands: &[StatusCommand]) {
        let mut slots = self.slots.lock().unwrap();
        for (idx, cmd) in commands.iter().enumerate() {
            if cmd.on_change == Some(true) {
                if let Some(slot) = slots.get_mut(&idx) {
                    slot.next_run = None;
                }
            }
        }
    }

    pub fn is_running(&self, index: usize) -> bool {
        self.slots
            .lock()
            .ok()
            .and_then(|s| s.get(&index).map(|slot| slot.running_pid.is_some()))
            .unwrap_or(false)
    }

    pub fn stop_all(&self) {
        *self.stopped.lock().unwrap() = true;
        if let Ok(mut cb) = self.on_change_callback.lock() {
            *cb = None;
        }
        if let Ok(mut slots) = self.slots.lock() {
            for slot in slots.values_mut() {
                if let Some(pid) = slot.running_pid.take() {
                    unsafe {
                        libc::kill(pid as i32, libc::SIGKILL);
                    }
                }
            }
        }
    }
}
