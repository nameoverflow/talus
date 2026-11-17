//! Coalesce session snapshots without filesystem work on the input path.
use crate::virtual_workspaces::PersistedWorkspaceSession;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{mpsc, Arc};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

enum Message {
    Save(PersistedWorkspaceSession),
    Flush(mpsc::Sender<()>),
    Stop,
}

pub struct SessionWriter {
    sender: mpsc::Sender<Message>,
    failed: Arc<AtomicBool>,
    worker: Option<JoinHandle<()>>,
}

impl SessionWriter {
    pub fn new(path: PathBuf) -> Self {
        let (sender, receiver) = mpsc::channel();
        let failed = Arc::new(AtomicBool::new(false));
        let failed_on_worker = failed.clone();
        let worker = thread::spawn(move || {
            let mut pending: Option<PersistedWorkspaceSession> = None;
            let mut deadline: Option<Instant> = None;
            let save = |pending: &mut Option<PersistedWorkspaceSession>| {
                if let Some(snapshot) = pending.take() {
                    if let Err(error) = snapshot.save_to_path(&path) {
                        eprintln!("Talus session save failed: {error}");
                        failed_on_worker.store(true, Ordering::Release);
                        *pending = Some(snapshot);
                    } else {
                        failed_on_worker.store(false, Ordering::Release);
                    }
                }
            };
            loop {
                let message = match deadline {
                    Some(at) => receiver.recv_timeout(at.saturating_duration_since(Instant::now())),
                    None => receiver
                        .recv()
                        .map_err(|_| mpsc::RecvTimeoutError::Disconnected),
                };
                match message {
                    Ok(Message::Save(snapshot)) => {
                        pending = Some(snapshot);
                        // A fixed deadline also saves during continuous key repeat.
                        deadline.get_or_insert_with(|| Instant::now() + Duration::from_millis(50));
                    }
                    Ok(Message::Flush(done)) => {
                        save(&mut pending);
                        deadline = None;
                        let _ = done.send(());
                    }
                    Err(mpsc::RecvTimeoutError::Timeout) => {
                        save(&mut pending);
                        deadline = None;
                    }
                    Ok(Message::Stop) | Err(mpsc::RecvTimeoutError::Disconnected) => {
                        save(&mut pending);
                        break;
                    }
                }
            }
        });
        Self {
            sender,
            failed,
            worker: Some(worker),
        }
    }

    pub fn failed(&self) -> bool {
        self.failed.load(Ordering::Acquire)
    }

    pub fn submit(&self, snapshot: PersistedWorkspaceSession) -> bool {
        self.sender.send(Message::Save(snapshot)).is_ok()
    }

    pub fn flush(&self) {
        let (sender, receiver) = mpsc::channel();
        if self.sender.send(Message::Flush(sender)).is_ok() {
            let _ = receiver.recv();
        }
    }
}

impl Drop for SessionWriter {
    fn drop(&mut self) {
        let _ = self.sender.send(Message::Stop);
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn flush_and_drop_keep_latest_snapshot_and_retry_failed_writes() {
        let dir = std::env::temp_dir().join(format!(
            "talus-writer-{}-{:?}",
            std::process::id(),
            Instant::now()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let blocker = dir.join("blocked");
        std::fs::write(&blocker, "not a directory").unwrap();
        let path = blocker.join("session.json");
        let writer = SessionWriter::new(path.clone());
        let mut snapshot = PersistedWorkspaceSession::default();
        writer.submit(snapshot.clone());
        writer.flush();
        assert!(writer.failed());
        std::fs::remove_file(&blocker).unwrap();
        for workspace in 0..20 {
            snapshot.active_workspace = workspace;
            writer.submit(snapshot.clone());
        }
        writer.flush();
        assert!(!writer.failed());
        assert_eq!(
            PersistedWorkspaceSession::load_from_path(&path),
            Some(snapshot.clone())
        );
        snapshot.active_workspace = 42;
        writer.submit(snapshot.clone());
        drop(writer);
        assert_eq!(
            PersistedWorkspaceSession::load_from_path(&path),
            Some(snapshot)
        );
        std::fs::remove_dir_all(dir).unwrap();
    }
}
