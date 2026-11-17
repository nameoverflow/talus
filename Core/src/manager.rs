use crate::config::{Configuration, FloatWindowRule, WorkspaceTarget};
use crate::layout::{
    centered_frame, centered_origin, inset_area, mirror_tall_layout_with_gaps,
    tall_layout_with_gaps, Rect,
};
use crate::screen_geometry::{is_parked_window_frame, parked_window_origin};
use crate::status_markup::SpaceEntry;
use crate::virtual_workspaces::{
    PersistedWindowRect, PersistedWorkspaceSession, VirtualWorkspaceEngine,
};
use crate::window_history::{merge_history, order_using_history};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::PathBuf;

pub const KVK_ANSI_A: u32 = 0x00;
pub const KVK_ANSI_H: u32 = 0x04;
pub const KVK_ANSI_J: u32 = 0x26;
pub const KVK_ANSI_K: u32 = 0x28;
pub const KVK_ANSI_L: u32 = 0x25;
pub const KVK_ANSI_P: u32 = 0x23;
pub const KVK_ANSI_T: u32 = 0x11;
pub const KVK_ANSI_COMMA: u32 = 0x2B;
pub const KVK_ANSI_PERIOD: u32 = 0x2F;
pub const KVK_RETURN: u32 = 0x24;
pub const KVK_SPACE: u32 = 0x31;

pub const WORKSPACE_DIGIT_KEY_CODES: [u32; 9] = [
    0x12, // kVK_ANSI_1
    0x13, // kVK_ANSI_2
    0x14, // kVK_ANSI_3
    0x15, // kVK_ANSI_4
    0x17, // kVK_ANSI_5
    0x16, // kVK_ANSI_6
    0x1A, // kVK_ANSI_7
    0x1C, // kVK_ANSI_8
    0x19, // kVK_ANSI_9
];

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ScreenSpec {
    pub id: usize,
    pub visible_frame: Rect,
    pub full_frame: Rect,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CandidateWindow {
    pub key: u64,
    pub pid: i32,
    pub bundle_id: Option<String>,
    pub window_id: Option<u32>,
    pub title: String,
    pub frame: Rect,
    pub is_resizable: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TrackedWindow {
    pub key: u64,
    pub pid: i32,
    pub bundle_id: Option<String>,
    pub window_id: Option<u32>,
    pub title: String,
    pub screen_id: usize,
    pub is_resizable: bool,
    pub frame: Rect,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum WindowEffect {
    SetFrame { key: u64, rect: Rect },
    SetPosition { key: u64, x: f64, y: f64 },
    Focus { key: u64, pid: i32 },
    RelinquishFocus,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct ManagerActionOutput {
    pub effects: Vec<WindowEffect>,
    pub active_window_keys: Vec<u64>,
    pub observe_window_keys: Vec<u64>,
    pub paused: bool,
    pub paused_toggled: Option<bool>,
    pub layout_name: String,
    pub active_workspace: usize,
    pub workspace_count: usize,
    pub is_virtual_mode: bool,
    pub status_changed: bool,
    pub trace_log: Option<String>,
}

pub struct ManagerCore {
    pub windows: Vec<TrackedWindow>,
    pub history: Vec<u64>,
    pub floating: HashSet<u64>,
    pub auto_floated_keys: HashSet<u64>,
    pub user_toggled_float_keys: HashSet<u64>,
    pub saved_frames: HashMap<u64, Rect>,
    pub home_screens: HashMap<u64, usize>,
    pub parked_keys: HashSet<u64>,
    pub window_by_key: HashMap<u64, TrackedWindow>,
    pub last_screens: Vec<ScreenSpec>,

    pub workspace_mode: String,
    pub virtual_engine: VirtualWorkspaceEngine<u64>,
    pub virtual_seeded: bool,
    pub suppress_external_focus_until: f64,
    pub programmatic_focus_key: Option<u64>,
    pub programmatic_focus_until: f64,

    pub session_file_path: Option<PathBuf>,
    pub last_workspace_by_window_id: HashMap<u32, usize>,
    pub persisted_window_rank: HashMap<u32, usize>,
    pub persisted_focused_by_ws: HashMap<usize, u32>,
    pub persisted_floating_ids: HashSet<u32>,
    pub persisted_saved_frames: HashMap<u32, Rect>,
    last_saved_session: Option<PersistedWorkspaceSession>,

    native_ratio: f64,
    native_masters: usize,
    native_layout_mode: i32,

    pub paused: bool,
    pub ignored_apps: HashSet<String>,
    pub app_workspaces: BTreeMap<String, WorkspaceTarget>,
    pub float_windows: Vec<FloatWindowRule>,
    pub space_labels: Vec<String>,
    pub ratio_step: f64,
    pub outer_gap: f64,
    pub inner_gap: f64,
    pub last_focused: Option<u64>,
}

impl ManagerCore {
    pub fn new(config: &Configuration, session_file_path: Option<PathBuf>) -> Self {
        let mut core = Self {
            windows: Vec::new(),
            history: Vec::new(),
            floating: HashSet::new(),
            auto_floated_keys: HashSet::new(),
            user_toggled_float_keys: HashSet::new(),
            saved_frames: HashMap::new(),
            home_screens: HashMap::new(),
            parked_keys: HashSet::new(),
            window_by_key: HashMap::new(),
            last_screens: Vec::new(),
            workspace_mode: config.workspace_mode.clone(),
            virtual_engine: VirtualWorkspaceEngine::new(
                config.workspace_count,
                config.master_ratio,
                config.master_count,
            ),
            virtual_seeded: false,
            suppress_external_focus_until: 0.0,
            programmatic_focus_key: None,
            programmatic_focus_until: 0.0,
            session_file_path,
            last_workspace_by_window_id: HashMap::new(),
            persisted_window_rank: HashMap::new(),
            persisted_focused_by_ws: HashMap::new(),
            persisted_floating_ids: HashSet::new(),
            persisted_saved_frames: HashMap::new(),
            last_saved_session: None,
            native_ratio: config.master_ratio,
            native_masters: config.master_count,
            native_layout_mode: 0,
            paused: false,
            ignored_apps: config.ignore_apps.iter().cloned().collect(),
            app_workspaces: config.app_workspaces.clone(),
            float_windows: config.float_windows.clone(),
            space_labels: config.space_labels.clone(),
            ratio_step: config.ratio_step,
            outer_gap: config.outer_gap,
            inner_gap: config.inner_gap,
            last_focused: None,
        };
        if config.workspace_mode == "virtual" {
            core.load_persisted_session_if_available();
        }
        core
    }

    pub fn is_virtual_mode(&self) -> bool {
        self.workspace_mode == "virtual"
    }

    pub fn is_floating(&self, w: &TrackedWindow) -> bool {
        !w.is_resizable || self.floating.contains(&w.key)
    }

    pub fn current_layout_mode(&self) -> i32 {
        if self.is_virtual_mode() {
            self.virtual_engine.active_layout().layout_mode
        } else {
            self.native_layout_mode
        }
    }

    pub fn set_current_layout_mode(&mut self, mode: i32) {
        if self.is_virtual_mode() {
            self.virtual_engine.active_layout_mut().layout_mode = mode;
        } else {
            self.native_layout_mode = mode;
        }
    }

    pub fn current_ratio(&self) -> f64 {
        if self.is_virtual_mode() {
            self.virtual_engine.active_layout().ratio
        } else {
            self.native_ratio
        }
    }

    pub fn set_current_ratio(&mut self, ratio: f64) {
        if self.is_virtual_mode() {
            self.virtual_engine.active_layout_mut().ratio = ratio;
        } else {
            self.native_ratio = ratio;
        }
    }

    pub fn current_masters(&self) -> usize {
        if self.is_virtual_mode() {
            self.virtual_engine.active_layout().masters
        } else {
            self.native_masters
        }
    }

    pub fn set_current_masters(&mut self, masters: usize) {
        if self.is_virtual_mode() {
            self.virtual_engine.active_layout_mut().masters = masters;
        } else {
            self.native_masters = masters;
        }
    }

    pub fn layout_name(&self) -> &'static str {
        match self.current_layout_mode() {
            1 => "Mirror",
            2 => "Full",
            _ => "Tall",
        }
    }

    fn load_persisted_session_if_available(&mut self) {
        let Some(ref path) = self.session_file_path else {
            return;
        };
        let Some(restored) = PersistedWorkspaceSession::load_from_path(path) else {
            return;
        };
        self.virtual_engine
            .restore_layouts_and_active(restored.active_workspace, &restored.layouts);
        self.last_workspace_by_window_id.clear();
        self.persisted_window_rank.clear();
        let mut rank = 0usize;
        for (ws, wids) in restored.workspace_window_ids.iter().enumerate() {
            let clamped_ws = ws.min(self.virtual_engine.count.saturating_sub(1));
            for &wid in wids {
                self.last_workspace_by_window_id.insert(wid, clamped_ws);
                self.persisted_window_rank.insert(wid, rank);
                rank += 1;
            }
        }
        self.persisted_focused_by_ws = restored.focused_by_workspace_map();
        self.persisted_floating_ids = restored.floating_window_ids.iter().copied().collect();
        self.persisted_saved_frames.clear();
        for (wid, rect) in restored.saved_frames_map() {
            self.persisted_saved_frames
                .insert(wid, Rect::new(rect.x, rect.y, rect.width, rect.height));
        }
        self.last_saved_session = Some(restored);
    }

    pub fn should_auto_float(&self, bundle_id: Option<&str>, title: &str) -> bool {
        self.float_windows
            .iter()
            .any(|r| r.matches(bundle_id, title))
    }

    pub fn assigned_workspace(&self, bundle_id: Option<&str>) -> Option<usize> {
        let b = bundle_id?;
        let target = self.app_workspaces.get(b)?;
        target.resolve(self.virtual_engine.count, &self.space_labels)
    }

    pub fn record_current_session_state(&mut self) {
        if !self.is_virtual_mode() || !self.virtual_seeded {
            return;
        }
        for (ws, keys) in self.virtual_engine.stacks.iter().enumerate() {
            for key in keys {
                if let Some(wid) = self.window_by_key.get(key).and_then(|w| w.window_id) {
                    self.last_workspace_by_window_id.insert(wid, ws);
                }
            }
        }
        let Some(ref path) = self.session_file_path else {
            return;
        };
        let workspace_window_ids: Vec<Vec<u32>> = self
            .virtual_engine
            .stacks
            .iter()
            .map(|stack| {
                stack
                    .iter()
                    .filter_map(|k| self.window_by_key.get(k).and_then(|w| w.window_id))
                    .collect()
            })
            .collect();
        let mut focused_map: HashMap<usize, u32> = HashMap::new();
        for ws in 0..self.virtual_engine.count {
            let focus_key = self
                .virtual_engine
                .focused_by_workspace
                .get(&ws)
                .copied()
                .or_else(|| self.virtual_engine.stacks[ws].first().copied());
            if let Some(fk) = focus_key {
                if let Some(wid) = self.window_by_key.get(&fk).and_then(|w| w.window_id) {
                    focused_map.insert(ws, wid);
                }
            }
        }
        let floating_ids: Vec<u32> = self
            .floating
            .iter()
            .filter_map(|k| self.window_by_key.get(k).and_then(|w| w.window_id))
            .collect();
        let mut frames_out: HashMap<u32, PersistedWindowRect> = HashMap::new();
        for (k, rect) in &self.saved_frames {
            if let Some(wid) = self.window_by_key.get(k).and_then(|w| w.window_id) {
                frames_out.insert(
                    wid,
                    PersistedWindowRect {
                        x: rect.x,
                        y: rect.y,
                        width: rect.w,
                        height: rect.h,
                    },
                );
            }
        }
        let snapshot = PersistedWorkspaceSession::new(
            self.virtual_engine.active,
            self.virtual_engine.layouts.clone(),
            workspace_window_ids,
            &focused_map,
            &floating_ids,
            &frames_out,
        );
        if self.last_saved_session.as_ref() == Some(&snapshot) {
            return;
        }
        if let Err(e) = snapshot.save_to_path(path) {
            eprintln!("Talus session save failed: {}", e);
        } else {
            self.last_saved_session = Some(snapshot);
        }
    }

    fn screen_for_id(&self, screen_id: usize) -> Option<&ScreenSpec> {
        self.last_screens
            .iter()
            .find(|s| s.id == screen_id)
            .or_else(|| self.last_screens.first())
    }

    pub fn update_live_frames(&mut self, live_frames: &HashMap<u64, Rect>) {
        for (&k, &rect) in live_frames {
            if let Some(w) = self.window_by_key.get_mut(&k) {
                w.frame = rect;
            }
            for w in &mut self.windows {
                if w.key == k {
                    w.frame = rect;
                }
            }
        }
    }

    pub fn restore_all_parked_windows(
        &mut self,
        trusted: bool,
        live_frames: &HashMap<u64, Rect>,
    ) -> Vec<WindowEffect> {
        self.update_live_frames(live_frames);
        if !trusted {
            self.parked_keys.clear();
            return Vec::new();
        }
        let mut keys_to_restore: Vec<u64> = self.parked_keys.iter().copied().collect();
        for (&key, win) in &self.window_by_key {
            if let Some(scr) = self.screen_for_id(win.screen_id) {
                if is_parked_window_frame(win.frame, scr.full_frame)
                    && !keys_to_restore.contains(&key)
                {
                    keys_to_restore.push(key);
                }
            }
        }
        keys_to_restore.sort_unstable();
        let mut effects = Vec::new();
        for key in keys_to_restore {
            let win = self.window_by_key.get(&key);
            let screen_id = win
                .map(|w| w.screen_id)
                .or_else(|| self.home_screens.get(&key).copied())
                .unwrap_or(0);
            let resizable = win.map(|w| w.is_resizable).unwrap_or(true);
            if let Some(&saved) = self.saved_frames.get(&key) {
                if resizable {
                    effects.push(WindowEffect::SetFrame { key, rect: saved });
                } else {
                    effects.push(WindowEffect::SetPosition {
                        key,
                        x: saved.x,
                        y: saved.y,
                    });
                }
            } else if let (Some(w), Some(scr)) = (win, self.screen_for_id(screen_id)) {
                if resizable {
                    let rect = centered_frame(w.frame.w, w.frame.h, scr.visible_frame);
                    effects.push(WindowEffect::SetFrame { key, rect });
                } else {
                    let (x, y) = centered_origin(w.frame.w, w.frame.h, scr.visible_frame);
                    effects.push(WindowEffect::SetPosition { key, x, y });
                }
            }
        }
        self.parked_keys.clear();
        effects
    }

    pub fn remember_focus(&mut self, now: f64, frontmost_key: Option<u64>) {
        let Some(fk) = frontmost_key else { return };
        if !self.windows.iter().any(|w| w.key == fk) {
            return;
        }
        if now < self.programmatic_focus_until {
            if let Some(target) = self.programmatic_focus_key {
                if fk == target {
                    self.programmatic_focus_until = 0.0;
                } else {
                    return;
                }
            }
        }
        self.last_focused = Some(fk);
        if self.is_virtual_mode() {
            self.virtual_engine.set_active_focus(Some(fk));
        }
    }

    pub fn focused_index(&self, now: f64, frontmost_key: Option<u64>) -> Option<usize> {
        if now < self.programmatic_focus_until {
            if let Some(target) = self.programmatic_focus_key {
                if let Some(idx) = self.windows.iter().position(|w| w.key == target) {
                    return Some(idx);
                }
            }
        }
        if let Some(fk) = frontmost_key {
            if let Some(idx) = self.windows.iter().position(|w| w.key == fk) {
                return Some(idx);
            }
        }
        if self.is_virtual_mode() {
            if let Some(rem) = self.virtual_engine.active_focused() {
                return self.windows.iter().position(|w| w.key == rem);
            }
        }
        None
    }

    fn emit_focus(&mut self, w: &TrackedWindow, now: f64, effects: &mut Vec<WindowEffect>) {
        self.last_focused = Some(w.key);
        self.programmatic_focus_key = Some(w.key);
        let deadline = now + 0.45;
        self.programmatic_focus_until = deadline;
        if deadline > self.suppress_external_focus_until {
            self.suppress_external_focus_until = deadline;
        }
        if self.is_virtual_mode() {
            self.virtual_engine.set_active_focus(Some(w.key));
        }
        effects.push(WindowEffect::Focus {
            key: w.key,
            pid: w.pid,
        });
    }

    fn emit_relinquish_focus(&mut self, effects: &mut Vec<WindowEffect>) {
        self.last_focused = None;
        self.programmatic_focus_key = None;
        self.programmatic_focus_until = 0.0;
        effects.push(WindowEffect::RelinquishFocus);
    }

    fn tile(&mut self, now: f64, frontmost_key: Option<u64>, effects: &mut Vec<WindowEffect>) {
        let screens = self.last_screens.clone();
        let mode = self.current_layout_mode();
        let ratio = self.current_ratio();
        let masters = self.current_masters();

        // 1. Unpark any floating (or fixed-size) windows belonging to the active workspace
        if self.is_virtual_mode() {
            let active_list = self.windows.clone();
            for w in &active_list {
                if !self.is_floating(w) {
                    continue;
                }
                let Some(scr) = self.screen_for_id(w.screen_id).cloned() else {
                    continue;
                };
                if self.parked_keys.contains(&w.key)
                    || is_parked_window_frame(w.frame, scr.full_frame)
                {
                    if w.is_resizable {
                        let restored =
                            self.saved_frames.get(&w.key).copied().unwrap_or_else(|| {
                                centered_frame(w.frame.w, w.frame.h, scr.visible_frame)
                            });
                        effects.push(WindowEffect::SetFrame {
                            key: w.key,
                            rect: restored,
                        });
                        if let Some(entry) = self.window_by_key.get_mut(&w.key) {
                            entry.frame = restored;
                        }
                    } else {
                        let (ox, oy) = self
                            .saved_frames
                            .get(&w.key)
                            .map(|r| (r.x, r.y))
                            .unwrap_or_else(|| {
                                centered_origin(w.frame.w, w.frame.h, scr.visible_frame)
                            });
                        effects.push(WindowEffect::SetPosition {
                            key: w.key,
                            x: ox,
                            y: oy,
                        });
                        if let Some(entry) = self.window_by_key.get_mut(&w.key) {
                            entry.frame.x = ox;
                            entry.frame.y = oy;
                        }
                    }
                    self.parked_keys.remove(&w.key);
                }
            }
        }

        // 2. Tile resizable non-floating windows on each display
        let current_focused = self
            .focused_index(now, frontmost_key)
            .and_then(|idx| self.windows.get(idx).cloned());

        for scr in &screens {
            let group: Vec<TrackedWindow> = self
                .windows
                .iter()
                .filter(|w| w.screen_id == scr.id && !self.is_floating(w))
                .cloned()
                .collect();
            if group.is_empty() {
                continue;
            }
            let rect = scr.visible_frame;
            let rects = match mode {
                1 => mirror_tall_layout_with_gaps(
                    rect,
                    group.len(),
                    masters,
                    ratio,
                    self.outer_gap,
                    self.inner_gap,
                ),
                2 => vec![inset_area(rect, self.outer_gap); group.len()],
                _ => tall_layout_with_gaps(
                    rect,
                    group.len(),
                    masters,
                    ratio,
                    self.outer_gap,
                    self.inner_gap,
                ),
            };
            for (w, target_rect) in group.iter().zip(rects.into_iter()) {
                let cur = self
                    .window_by_key
                    .get(&w.key)
                    .map(|e| e.frame)
                    .unwrap_or(w.frame);
                if (cur.x - target_rect.x).abs() < 1.0
                    && (cur.y - target_rect.y).abs() < 1.0
                    && (cur.w - target_rect.w).abs() < 1.0
                    && (cur.h - target_rect.h).abs() < 1.0
                {
                    // Already at target frame
                } else {
                    effects.push(WindowEffect::SetFrame {
                        key: w.key,
                        rect: target_rect,
                    });
                    if let Some(entry) = self.window_by_key.get_mut(&w.key) {
                        entry.frame = target_rect;
                    }
                }
                self.parked_keys.remove(&w.key);
            }
            if mode == 2 {
                if let Some(ref cur_win) = current_focused {
                    if cur_win.screen_id == scr.id {
                        self.emit_focus(cur_win, now, effects);
                    }
                }
            }
        }

        // 3. Park windows belonging to inactive virtual workspaces at 1px corner
        if self.is_virtual_mode() {
            let all_full_rects: Vec<Rect> = screens.iter().map(|s| s.full_frame).collect();
            for key in self.virtual_engine.inactive_windows() {
                let Some(w) = self.window_by_key.get(&key).cloned() else {
                    continue;
                };
                let Some(scr) = self.screen_for_id(w.screen_id).cloned() else {
                    continue;
                };
                if !is_parked_window_frame(w.frame, scr.full_frame) {
                    if !w.is_resizable
                        || self.floating.contains(&key)
                        || !self.saved_frames.contains_key(&key)
                    {
                        self.saved_frames.insert(key, w.frame);
                    }
                    let (ox, oy) =
                        parked_window_origin(w.frame.w, w.frame.h, scr.full_frame, &all_full_rects);
                    effects.push(WindowEffect::SetPosition { key, x: ox, y: oy });
                    if let Some(entry) = self.window_by_key.get_mut(&key) {
                        entry.frame.x = ox;
                        entry.frame.y = oy;
                    }
                }
                self.parked_keys.insert(key);
            }
        }

        // Sync updated frames back into `self.windows`
        for w in &mut self.windows {
            if let Some(updated) = self.window_by_key.get(&w.key) {
                w.frame = updated.frame;
            }
        }
    }

    fn update_history(&mut self, alive_keys: Option<&HashSet<u64>>, dead_keys: &[u64]) {
        let dead_set: HashSet<u64> = dead_keys.iter().copied().collect();
        self.history.retain(|k| !dead_set.contains(k));
        let active_keys: Vec<u64> = self.windows.iter().map(|w| w.key).collect();
        self.history = merge_history(&self.history, &active_keys, |a, b| a == b);

        let mut known_alive: HashSet<u64> = self.history.iter().copied().collect();
        if let Some(alive) = alive_keys {
            known_alive.extend(alive.iter().copied());
        }
        self.floating.retain(|k| known_alive.contains(k));
        self.auto_floated_keys.retain(|k| known_alive.contains(k));
        self.user_toggled_float_keys
            .retain(|k| known_alive.contains(k));
        self.saved_frames.retain(|k, _| known_alive.contains(k));
        self.home_screens.retain(|k, _| known_alive.contains(k));
        self.parked_keys.retain(|k| known_alive.contains(k));
    }

    fn make_output(&self, effects: Vec<WindowEffect>) -> ManagerActionOutput {
        ManagerActionOutput {
            effects,
            active_window_keys: self.windows.iter().map(|w| w.key).collect(),
            observe_window_keys: self.window_by_key.keys().copied().collect(),
            paused: self.paused,
            paused_toggled: None,
            layout_name: self.layout_name().to_string(),
            active_workspace: self.virtual_engine.active,
            workspace_count: self.virtual_engine.count,
            is_virtual_mode: self.is_virtual_mode(),
            status_changed: true,
            trace_log: None,
        }
    }

    #[allow(clippy::too_many_arguments)]
    pub fn refresh(
        &mut self,
        force: bool,
        now: f64,
        screens: Vec<ScreenSpec>,
        candidates: Vec<CandidateWindow>,
        busy_pids: &[i32],
        visible_window_ids: &[u32],
        all_existing_cg_window_ids: &[u32],
        dead_history_keys: &[u32],
        dead_history_u64: &[u64],
        eligible_visible_window_exists: bool,
        frontmost_key: Option<u64>,
        trace_events: bool,
    ) -> ManagerActionOutput {
        let _ = dead_history_keys;
        if self.paused || screens.is_empty() {
            return self.make_output(Vec::new());
        }
        self.last_screens = screens.clone();

        if !all_existing_cg_window_ids.is_empty() {
            let existing_set: HashSet<u32> = all_existing_cg_window_ids.iter().copied().collect();
            self.last_workspace_by_window_id
                .retain(|k, _| existing_set.contains(k));
            self.persisted_window_rank
                .retain(|k, _| existing_set.contains(k));
            self.persisted_floating_ids
                .retain(|k| existing_set.contains(k));
            self.persisted_saved_frames
                .retain(|k, _| existing_set.contains(k));
        }

        let visible_wid_set: HashSet<u32> = visible_window_ids.iter().copied().collect();
        let busy_pid_set: HashSet<i32> = busy_pids.iter().copied().collect();

        let mut effects: Vec<WindowEffect> = Vec::new();
        let mut found: Vec<TrackedWindow> = Vec::new();
        let mut next_map: HashMap<u64, TrackedWindow> = HashMap::new();
        let mut newly_auto_floated_on_active: Vec<u64> = Vec::new();

        // Carry forward windows from transient busy PIDs
        for prev_win in self.window_by_key.values() {
            if busy_pid_set.contains(&prev_win.pid) {
                if let Some(wid) = prev_win.window_id {
                    if visible_wid_set.contains(&wid) {
                        found.push(prev_win.clone());
                        next_map.insert(prev_win.key, prev_win.clone());
                    }
                }
            }
        }

        for cand in candidates {
            if next_map.contains_key(&cand.key) {
                continue;
            }
            if let Some(ref b) = cand.bundle_id {
                if self.ignored_apps.contains(b) {
                    continue;
                }
            }
            if !self.is_virtual_mode() && !cand.is_resizable {
                continue;
            }

            let mut f = cand.frame;
            let resolved_screen = if let Some(&home_id) = self.home_screens.get(&cand.key) {
                if let Some(home_scr) = screens.iter().find(|s| s.id == home_id) {
                    if is_parked_window_frame(f, home_scr.full_frame) {
                        Some(home_scr.clone())
                    } else {
                        None
                    }
                } else {
                    None
                }
            } else {
                None
            }
            .or_else(|| {
                screens
                    .iter()
                    .max_by(|a, b| {
                        a.full_frame
                            .intersection_area(&f)
                            .partial_cmp(&b.full_frame.intersection_area(&f))
                            .unwrap_or(std::cmp::Ordering::Equal)
                    })
                    .cloned()
            });

            let Some(screen) = resolved_screen else {
                continue;
            };
            if !screen.full_frame.intersects(&f) {
                continue;
            }

            if let Some(wid) = cand.window_id {
                if let Some(persisted_rect) = self.persisted_saved_frames.remove(&wid) {
                    self.saved_frames.entry(cand.key).or_insert(persisted_rect);
                }
                if self.persisted_floating_ids.remove(&wid) {
                    self.floating.insert(cand.key);
                    if !self.should_auto_float(cand.bundle_id.as_deref(), &cand.title) {
                        self.user_toggled_float_keys.insert(cand.key);
                    } else {
                        self.auto_floated_keys.insert(cand.key);
                    }
                }
            }

            if cand.is_resizable && !self.user_toggled_float_keys.contains(&cand.key) {
                if self.should_auto_float(cand.bundle_id.as_deref(), &cand.title) {
                    let was_floating = self.floating.contains(&cand.key);
                    self.floating.insert(cand.key);
                    self.auto_floated_keys.insert(cand.key);
                    if !was_floating && self.window_by_key.contains_key(&cand.key) {
                        newly_auto_floated_on_active.push(cand.key);
                    }
                } else if self.auto_floated_keys.contains(&cand.key) {
                    self.floating.remove(&cand.key);
                    self.auto_floated_keys.remove(&cand.key);
                }
            }

            let parked_now = is_parked_window_frame(f, screen.full_frame);
            let belongs_to_inactive_on_seed = if self.is_virtual_mode() && !self.virtual_seeded {
                let target_ws = cand
                    .window_id
                    .and_then(|wid| self.last_workspace_by_window_id.get(&wid).copied())
                    .or_else(|| self.assigned_workspace(cand.bundle_id.as_deref()));
                target_ws
                    .map(|ws| ws != self.virtual_engine.active)
                    .unwrap_or(false)
            } else {
                false
            };

            if parked_now && !self.parked_keys.contains(&cand.key) {
                if belongs_to_inactive_on_seed {
                    self.home_screens.insert(cand.key, screen.id);
                    self.parked_keys.insert(cand.key);
                } else if cand.is_resizable {
                    let rescued = self
                        .saved_frames
                        .get(&cand.key)
                        .copied()
                        .unwrap_or_else(|| centered_frame(f.w, f.h, screen.visible_frame));
                    effects.push(WindowEffect::SetFrame {
                        key: cand.key,
                        rect: rescued,
                    });
                    f = rescued;
                } else {
                    let (ox, oy) = self
                        .saved_frames
                        .get(&cand.key)
                        .map(|r| (r.x, r.y))
                        .unwrap_or_else(|| centered_origin(f.w, f.h, screen.visible_frame));
                    effects.push(WindowEffect::SetPosition {
                        key: cand.key,
                        x: ox,
                        y: oy,
                    });
                    f.x = ox;
                    f.y = oy;
                }
            } else if !parked_now {
                self.home_screens.insert(cand.key, screen.id);
                if !self.saved_frames.contains_key(&cand.key)
                    || self.floating.contains(&cand.key)
                    || !cand.is_resizable
                {
                    let area = screen.visible_frame;
                    let inset = inset_area(area, self.outer_gap);
                    let matches_full_tiled = ((f.w - area.w).abs() <= 4.0
                        && (f.h - area.h).abs() <= 4.0)
                        || ((f.w - inset.w).abs() <= 4.0 && (f.h - inset.h).abs() <= 4.0);
                    if newly_auto_floated_on_active.contains(&cand.key) && matches_full_tiled {
                        let fallback = centered_frame(
                            (area.w * 0.72).min(960.0),
                            (area.h * 0.76).min(720.0),
                            area,
                        );
                        self.saved_frames.insert(cand.key, fallback);
                        effects.push(WindowEffect::SetFrame {
                            key: cand.key,
                            rect: fallback,
                        });
                        f = fallback;
                    } else {
                        self.saved_frames.insert(cand.key, f);
                    }
                }
            }

            let win = TrackedWindow {
                key: cand.key,
                pid: cand.pid,
                bundle_id: cand.bundle_id,
                window_id: cand.window_id,
                title: cand.title,
                screen_id: screen.id,
                is_resizable: cand.is_resizable,
                frame: f,
            };
            found.push(win.clone());
            next_map.insert(win.key, win);
        }

        if self.is_virtual_mode()
            && found.is_empty()
            && eligible_visible_window_exists
            && self.virtual_seeded
            && !self.virtual_engine.all_windows().is_empty()
        {
            return self.make_output(effects);
        }

        self.window_by_key = next_map.clone();

        if self.is_virtual_mode() {
            let effective_front = if now >= self.suppress_external_focus_until {
                frontmost_key
            } else {
                None
            };
            if !self.virtual_seeded && (!found.is_empty() || !eligible_visible_window_exists) {
                let found_keys: Vec<u64> = found.iter().map(|w| w.key).collect();
                let mut ordered_seed =
                    order_using_history(&found_keys, &self.history, |a, b| a == b);
                for &k in &found_keys {
                    if !ordered_seed.contains(&k) {
                        ordered_seed.push(k);
                    }
                }
                let last_ws_map = self.last_workspace_by_window_id.clone();
                let app_ws_map = self.app_workspaces.clone();
                let ws_count = self.virtual_engine.count;
                let labels = self.space_labels.clone();
                let rank_map = self.persisted_window_rank.clone();
                let focus_map = self.persisted_focused_by_ws.clone();

                self.virtual_engine.seed_from_current_desktop(
                    &ordered_seed,
                    effective_front.as_ref(),
                    |key| {
                        let win = next_map.get(key)?;
                        if let Some(wid) = win.window_id {
                            if let Some(&prev_ws) = last_ws_map.get(&wid) {
                                return Some(prev_ws);
                            }
                        }
                        let b = win.bundle_id.as_deref()?;
                        app_ws_map.get(b)?.resolve(ws_count, &labels)
                    },
                    |key| {
                        let wid = next_map.get(key)?.window_id?;
                        rank_map.get(&wid).copied()
                    },
                    |ws, candidates| {
                        let target_wid = *focus_map.get(&ws)?;
                        candidates
                            .iter()
                            .find(|k| {
                                next_map.get(*k).and_then(|w| w.window_id) == Some(target_wid)
                            })
                            .copied()
                    },
                );
                self.persisted_window_rank.clear();
                self.persisted_focused_by_ws.clear();
                self.virtual_seeded = true;
            }

            let switched_externally = effective_front
                .and_then(|fk| self.virtual_engine.handle_external_focus(&fk))
                .is_some();

            let found_keys: Vec<u64> = found.iter().map(|w| w.key).collect();
            let last_ws_map = self.last_workspace_by_window_id.clone();
            let app_ws_map = self.app_workspaces.clone();
            let ws_count = self.virtual_engine.count;
            let labels = self.space_labels.clone();
            let floating_set = self.floating.clone();
            let active_ws = self.virtual_engine.active;
            let active_pids: HashSet<i32> = self
                .virtual_engine
                .active_windows()
                .iter()
                .filter_map(|k| next_map.get(k).map(|w| w.pid))
                .collect();

            let (stacks_changed, auto_shifted) = self.virtual_engine.reconcile(
                &found_keys,
                effective_front.as_ref(),
                |key| {
                    let win = next_map.get(key)?;
                    if let Some(wid) = win.window_id {
                        if let Some(&prev_ws) = last_ws_map.get(&wid) {
                            return Some(prev_ws);
                        }
                    }
                    if floating_set.contains(key) && active_pids.contains(&win.pid) {
                        return Some(active_ws);
                    }
                    let b = win.bundle_id.as_deref()?;
                    app_ws_map.get(b)?.resolve(ws_count, &labels)
                },
                |new_key, anchor_key| {
                    next_map.get(new_key).map(|w| w.screen_id)
                        == next_map.get(anchor_key).map(|w| w.screen_id)
                },
            );

            if !auto_shifted.is_empty() {
                self.suppress_external_focus_until = now + 0.65;
            }

            let next_active_windows: Vec<TrackedWindow> = self
                .virtual_engine
                .active_windows()
                .iter()
                .filter_map(|k| next_map.get(k).cloned())
                .collect();

            let prev_windows = self.windows.clone();
            let active_changed = !newly_auto_floated_on_active.is_empty()
                || next_active_windows.len() != prev_windows.len()
                || next_active_windows
                    .iter()
                    .zip(prev_windows.iter())
                    .any(|(a, b)| {
                        a.key != b.key
                            || a.screen_id != b.screen_id
                            || a.is_resizable != b.is_resizable
                            || self.is_floating(a) != self.is_floating(b)
                    });

            self.windows = next_active_windows;
            if let Some(focused) = self.virtual_engine.active_focused() {
                self.last_focused = Some(focused);
            }
            let alive_keys: HashSet<u64> = next_map.keys().copied().collect();
            self.update_history(Some(&alive_keys), dead_history_u64);

            let trace_log = if trace_events {
                Some(format!(
                    "refresh(virtual) ws={} active={} total={} changed={}",
                    self.virtual_engine.active + 1,
                    self.windows.len(),
                    found.len(),
                    stacks_changed || active_changed
                ))
            } else {
                None
            };

            if stacks_changed || active_changed || switched_externally || force {
                self.tile(now, frontmost_key, &mut effects);
            }
            if !auto_shifted.is_empty() {
                if frontmost_key.is_none()
                    || frontmost_key
                        .map(|fk| auto_shifted.contains(&fk))
                        .unwrap_or(false)
                {
                    if let Some(af) = self.virtual_engine.active_focused() {
                        if let Some(win) = next_map.get(&af).cloned() {
                            self.emit_focus(&win, now, &mut effects);
                        }
                    } else if self.windows.is_empty() {
                        self.emit_relinquish_focus(&mut effects);
                    }
                }
            }
            if self.virtual_seeded
                && (stacks_changed || active_changed || switched_externally || force)
            {
                self.record_current_session_state();
            }

            let mut out = self.make_output(effects);
            out.trace_log = trace_log;
            return out;
        }

        // Native Spaces mode
        let found_keys: Vec<u64> = found.iter().map(|w| w.key).collect();
        let mut ordered_keys = order_using_history(&found_keys, &self.history, |a, b| a == b);
        for w in &found {
            if !self.history.contains(&w.key) {
                ordered_keys.retain(|&k| k != w.key);
                if let Some(focused_key) = self.last_focused {
                    if let Some(idx) = ordered_keys.iter().position(|&k| {
                        k == focused_key
                            && next_map.get(&k).map(|ow| ow.screen_id) == Some(w.screen_id)
                    }) {
                        ordered_keys.insert(idx, w.key);
                        continue;
                    }
                }
                ordered_keys.push(w.key);
            }
        }
        let ordered: Vec<TrackedWindow> = ordered_keys
            .iter()
            .filter_map(|k| next_map.get(k).cloned())
            .collect();
        let changed = ordered.len() != self.windows.len()
            || ordered
                .iter()
                .zip(self.windows.iter())
                .any(|(a, b)| a.key != b.key || a.screen_id != b.screen_id);
        let trace_log = if trace_events {
            Some(format!(
                "refresh {:.6} windows={} changed={}",
                now,
                ordered.len(),
                changed
            ))
        } else {
            None
        };
        self.windows = ordered;
        self.remember_focus(now, frontmost_key);
        self.update_history(None, dead_history_u64);
        if changed || force {
            self.tile(now, frontmost_key, &mut effects);
        }
        let mut out = self.make_output(effects);
        out.trace_log = trace_log;
        out
    }

    pub fn handle_ax_focus_notification(
        &mut self,
        now: f64,
        trusted: bool,
        locked: bool,
        frontmost_key: Option<u64>,
        live_frames: &HashMap<u64, Rect>,
    ) -> ManagerActionOutput {
        self.update_live_frames(live_frames);
        if !self.is_virtual_mode()
            || self.paused
            || !trusted
            || locked
            || now < self.suppress_external_focus_until
        {
            self.remember_focus(now, frontmost_key);
            let mut out = self.make_output(Vec::new());
            out.status_changed = false;
            return out;
        }
        if let Some(fk) = frontmost_key {
            if self.virtual_engine.handle_external_focus(&fk).is_some() {
                self.last_focused = Some(fk);
                self.windows = self
                    .virtual_engine
                    .active_windows()
                    .iter()
                    .filter_map(|k| self.window_by_key.get(k).cloned())
                    .collect();
                let mut effects = Vec::new();
                self.tile(now, frontmost_key, &mut effects);
                if let Some(win) = self.window_by_key.get(&fk).cloned() {
                    self.emit_focus(&win, now, &mut effects);
                }
                self.record_current_session_state();
                return self.make_output(effects);
            }
        }
        self.remember_focus(now, frontmost_key);
        let mut out = self.make_output(Vec::new());
        out.status_changed = false;
        out
    }

    pub fn handle_application_activated(
        &mut self,
        pid: i32,
        now: f64,
        trusted: bool,
        locked: bool,
        app_focused_key: Option<u64>,
        live_frames: &HashMap<u64, Rect>,
    ) -> ManagerActionOutput {
        self.update_live_frames(live_frames);
        if !self.is_virtual_mode()
            || self.paused
            || !trusted
            || locked
            || now < self.suppress_external_focus_until
        {
            let mut out = self.make_output(Vec::new());
            out.status_changed = false;
            return out;
        }
        let target_key = app_focused_key.or_else(|| {
            let app_keys: Vec<u64> = self
                .virtual_engine
                .all_windows()
                .into_iter()
                .filter(|k| self.window_by_key.get(k).map(|w| w.pid) == Some(pid))
                .collect();
            let active_set: HashSet<u64> =
                self.virtual_engine.active_windows().iter().copied().collect();
            if !app_keys.iter().any(|k| active_set.contains(k)) {
                app_keys.into_iter().next()
            } else {
                None
            }
        });

        if let Some(tk) = target_key {
            if self.virtual_engine.handle_external_focus(&tk).is_some() {
                self.last_focused = Some(tk);
                self.windows = self
                    .virtual_engine
                    .active_windows()
                    .iter()
                    .filter_map(|k| self.window_by_key.get(k).cloned())
                    .collect();
                let mut effects = Vec::new();
                self.tile(now, Some(tk), &mut effects);
                if let Some(win) = self.window_by_key.get(&tk).cloned() {
                    self.emit_focus(&win, now, &mut effects);
                }
                self.record_current_session_state();
                return self.make_output(effects);
            }
        }
        let mut out = self.make_output(Vec::new());
        out.status_changed = false;
        out
    }

    pub fn switch_workspace(
        &mut self,
        index: usize,
        now: f64,
        trusted: bool,
        frontmost_key: Option<u64>,
        live_frames: &HashMap<u64, Rect>,
    ) -> ManagerActionOutput {
        self.update_live_frames(live_frames);
        if !self.is_virtual_mode() || self.paused || !trusted || index >= self.virtual_engine.count
        {
            return self.make_output(Vec::new());
        }
        self.remember_focus(now, frontmost_key);
        self.suppress_external_focus_until = now + 0.45;

        let mut effects = Vec::new();
        let changed = self.virtual_engine.switch_to(index);
        if changed {
            self.windows = self
                .virtual_engine
                .active_windows()
                .iter()
                .filter_map(|k| self.window_by_key.get(k).cloned())
                .collect();
            self.tile(now, frontmost_key, &mut effects);
        }
        if let Some(target_key) = self.virtual_engine.active_focused() {
            if let Some(target_win) = self.window_by_key.get(&target_key).cloned() {
                self.emit_focus(&target_win, now, &mut effects);
            }
        } else if self.windows.is_empty() {
            self.emit_relinquish_focus(&mut effects);
        }
        self.record_current_session_state();
        self.make_output(effects)
    }

    pub fn move_window_to_workspace(
        &mut self,
        index: usize,
        now: f64,
        trusted: bool,
        frontmost_key: Option<u64>,
        live_frames: &HashMap<u64, Rect>,
    ) -> ManagerActionOutput {
        self.update_live_frames(live_frames);
        if !self.is_virtual_mode() || self.paused || !trusted || index >= self.virtual_engine.count
        {
            return self.make_output(Vec::new());
        }
        let Some(i) = self.focused_index(now, frontmost_key) else {
            return self.make_output(Vec::new());
        };
        let moving = self.windows[i].clone();
        self.suppress_external_focus_until = now + 0.45;

        let (moved, next_focus_on_active) = self.virtual_engine.move_window(&moving.key, index);
        if !moved {
            return self.make_output(Vec::new());
        }
        if let Some(wid) = moving.window_id {
            self.last_workspace_by_window_id.insert(wid, index);
        }

        self.windows = self
            .virtual_engine
            .active_windows()
            .iter()
            .filter_map(|k| self.window_by_key.get(k).cloned())
            .collect();
        let mut effects = Vec::new();
        self.tile(now, frontmost_key, &mut effects);

        if let Some(next_key) = next_focus_on_active {
            if let Some(next_win) = self.window_by_key.get(&next_key).cloned() {
                self.emit_focus(&next_win, now, &mut effects);
            } else {
                self.emit_relinquish_focus(&mut effects);
            }
        } else {
            self.emit_relinquish_focus(&mut effects);
        }
        self.record_current_session_state();
        self.make_output(effects)
    }

    fn sync_active_virtual_stack_from_windows(&mut self) {
        if self.is_virtual_mode() {
            let keys: Vec<u64> = self.windows.iter().map(|w| w.key).collect();
            self.virtual_engine.replace_active_stack(&keys);
        }
    }

    pub fn handle_key(
        &mut self,
        code: u32,
        shift: bool,
        now: f64,
        trusted: bool,
        frontmost_key: Option<u64>,
        live_frames: &HashMap<u64, Rect>,
    ) -> ManagerActionOutput {
        self.update_live_frames(live_frames);
        if code == KVK_ANSI_P {
            self.paused = !self.paused;
            let mut out = self.make_output(Vec::new());
            out.paused_toggled = Some(self.paused);
            return out;
        }
        if self.paused || !trusted {
            return self.make_output(Vec::new());
        }

        if self.is_virtual_mode() {
            if let Some(digit_idx) = WORKSPACE_DIGIT_KEY_CODES.iter().position(|&c| c == code) {
                if digit_idx < self.virtual_engine.count {
                    return if shift {
                        self.move_window_to_workspace(
                            digit_idx,
                            now,
                            trusted,
                            frontmost_key,
                            live_frames,
                        )
                    } else {
                        self.switch_workspace(digit_idx, now, trusted, frontmost_key, live_frames)
                    };
                }
            }
        }

        let mut effects = Vec::new();
        match code {
            KVK_ANSI_T => {
                let Some(i) = self.focused_index(now, frontmost_key) else {
                    return self.make_output(Vec::new());
                };
                if !self.windows[i].is_resizable {
                    return self.make_output(Vec::new());
                }
                let win = self.windows[i].clone();
                let Some(scr) = self.screen_for_id(win.screen_id).cloned() else {
                    return self.make_output(Vec::new());
                };
                self.user_toggled_float_keys.insert(win.key);
                self.auto_floated_keys.remove(&win.key);
                if self.floating.contains(&win.key) {
                    if !is_parked_window_frame(win.frame, scr.full_frame) {
                        self.saved_frames.insert(win.key, win.frame);
                    }
                    self.floating.remove(&win.key);
                    self.tile(now, frontmost_key, &mut effects);
                } else {
                    self.floating.insert(win.key);
                    self.tile(now, frontmost_key, &mut effects);
                    let area = scr.visible_frame;
                    let inset = inset_area(area, self.outer_gap);
                    let saved = self.saved_frames.get(&win.key).copied();
                    let use_saved = saved
                        .map(|s| {
                            let is_full =
                                (s.w - area.w).abs() <= 4.0 && (s.h - area.h).abs() <= 4.0;
                            let is_inset =
                                (s.w - inset.w).abs() <= 4.0 && (s.h - inset.h).abs() <= 4.0;
                            !is_full && !is_inset
                        })
                        .unwrap_or(false);
                    let restored = if use_saved {
                        saved.unwrap()
                    } else {
                        centered_frame(860.0, 600.0, area)
                    };
                    self.saved_frames.insert(win.key, restored);
                    effects.push(WindowEffect::SetFrame {
                        key: win.key,
                        rect: restored,
                    });
                    if let Some(entry) = self.window_by_key.get_mut(&win.key) {
                        entry.frame = restored;
                    }
                    self.emit_focus(&win, now, &mut effects);
                }
                self.record_current_session_state();
            }
            KVK_ANSI_H => {
                let next_r = (self.current_ratio() - self.ratio_step).max(0.2);
                self.set_current_ratio(next_r);
                self.tile(now, frontmost_key, &mut effects);
                self.record_current_session_state();
            }
            KVK_ANSI_L => {
                let next_r = (self.current_ratio() + self.ratio_step).min(0.8);
                self.set_current_ratio(next_r);
                self.tile(now, frontmost_key, &mut effects);
                self.record_current_session_state();
            }
            KVK_ANSI_COMMA => {
                let next_m = self.current_masters() + 1;
                self.set_current_masters(next_m);
                self.tile(now, frontmost_key, &mut effects);
                self.record_current_session_state();
            }
            KVK_ANSI_PERIOD => {
                let next_m = self.current_masters().saturating_sub(1).max(1);
                self.set_current_masters(next_m);
                self.tile(now, frontmost_key, &mut effects);
                self.record_current_session_state();
            }
            KVK_SPACE => {
                let next_mode = (self.current_layout_mode() + 1) % 3;
                self.set_current_layout_mode(next_mode);
                self.tile(now, frontmost_key, &mut effects);
                self.record_current_session_state();
            }
            KVK_ANSI_J | KVK_ANSI_K => {
                let Some(i) = self.focused_index(now, frontmost_key) else {
                    return self.make_output(Vec::new());
                };
                if self.windows.len() <= 1 {
                    return self.make_output(Vec::new());
                }
                let focus_screen = self.windows[i].screen_id;
                if shift {
                    let indices: Vec<usize> = (0..self.windows.len())
                        .filter(|&idx| {
                            self.windows[idx].screen_id == focus_screen
                                && !self.is_floating(&self.windows[idx])
                        })
                        .collect();
                    let Some(p) = indices.iter().position(|&idx| idx == i) else {
                        return self.make_output(Vec::new());
                    };
                    if indices.len() <= 1 {
                        return self.make_output(Vec::new());
                    }
                    let step = if code == KVK_ANSI_J {
                        1
                    } else {
                        indices.len() - 1
                    };
                    let next = indices[(p + step) % indices.len()];
                    let direction = if code == KVK_ANSI_J { 1 } else { -1 };
                    if (direction > 0 && p == indices.len() - 1) || (direction < 0 && p == 0) {
                        let mut group: Vec<TrackedWindow> =
                            indices.iter().map(|&idx| self.windows[idx].clone()).collect();
                        if direction > 0 {
                            if let Some(last) = group.pop() {
                                group.insert(0, last);
                            }
                        } else {
                            let first = group.remove(0);
                            group.push(first);
                        }
                        for (idx, win) in indices.into_iter().zip(group.into_iter()) {
                            self.windows[idx] = win;
                        }
                    } else {
                        self.windows.swap(i, next);
                    }
                    self.sync_active_virtual_stack_from_windows();
                    let alive = if self.is_virtual_mode() {
                        Some(self.window_by_key.keys().copied().collect::<HashSet<u64>>())
                    } else {
                        None
                    };
                    self.update_history(alive.as_ref(), &[]);
                    self.tile(now, frontmost_key, &mut effects);
                    self.record_current_session_state();
                } else {
                    let indices: Vec<usize> = (0..self.windows.len())
                        .filter(|&idx| self.windows[idx].screen_id == focus_screen)
                        .collect();
                    let Some(p) = indices.iter().position(|&idx| idx == i) else {
                        return self.make_output(Vec::new());
                    };
                    if indices.len() <= 1 {
                        return self.make_output(Vec::new());
                    }
                    let step = if code == KVK_ANSI_J {
                        1
                    } else {
                        indices.len() - 1
                    };
                    let next = indices[(p + step) % indices.len()];
                    let next_win = self.windows[next].clone();
                    self.emit_focus(&next_win, now, &mut effects);
                    self.record_current_session_state();
                }
            }
            KVK_RETURN => {
                let Some(i) = self.focused_index(now, frontmost_key) else {
                    return self.make_output(Vec::new());
                };
                if self.is_floating(&self.windows[i]) {
                    return self.make_output(Vec::new());
                }
                let focus_screen = self.windows[i].screen_id;
                let Some(first) = (0..self.windows.len()).find(|&idx| {
                    self.windows[idx].screen_id == focus_screen
                        && !self.is_floating(&self.windows[idx])
                }) else {
                    return self.make_output(Vec::new());
                };
                if first == i {
                    return self.make_output(Vec::new());
                }
                self.windows.swap(i, first);
                self.sync_active_virtual_stack_from_windows();
                let alive = if self.is_virtual_mode() {
                    Some(self.window_by_key.keys().copied().collect::<HashSet<u64>>())
                } else {
                    None
                };
                self.update_history(alive.as_ref(), &[]);
                self.tile(now, frontmost_key, &mut effects);
                self.record_current_session_state();
            }
            _ => {}
        }
        self.make_output(effects)
    }

    pub fn apply_config(
        &mut self,
        config: &Configuration,
        now: f64,
        trusted: bool,
        frontmost_key: Option<u64>,
        live_frames: &HashMap<u64, Rect>,
    ) -> ManagerActionOutput {
        self.update_live_frames(live_frames);
        let was_virtual = self.is_virtual_mode();
        let will_be_virtual = config.workspace_mode == "virtual";

        let mut previous_resolved: HashMap<String, usize> = HashMap::new();
        for (bundle, target) in &self.app_workspaces {
            if let Some(ws) = target.resolve(self.virtual_engine.count, &self.space_labels) {
                previous_resolved.insert(bundle.clone(), ws);
            }
        }

        self.native_ratio = config.master_ratio;
        self.native_masters = config.master_count;
        self.ratio_step = config.ratio_step;
        self.outer_gap = config.outer_gap;
        self.inner_gap = config.inner_gap;
        self.ignored_apps = config.ignore_apps.iter().cloned().collect();
        self.app_workspaces = config.app_workspaces.clone();
        self.float_windows = config.float_windows.clone();
        self.space_labels = config.space_labels.clone();
        self.virtual_engine
            .update_defaults(config.master_ratio, config.master_count);
        self.virtual_engine.resize_count(config.workspace_count);

        let mut effects = Vec::new();
        if was_virtual && !will_be_virtual {
            self.record_current_session_state();
            effects.extend(self.restore_all_parked_windows(trusted, live_frames));
            self.workspace_mode = "native".to_string();
            self.virtual_seeded = false;
        } else if !was_virtual && will_be_virtual {
            self.workspace_mode = "virtual".to_string();
            self.virtual_seeded = false;
            self.load_persisted_session_if_available();
        } else {
            self.workspace_mode = config.workspace_mode.clone();
            if will_be_virtual && self.virtual_seeded {
                let mut moved_any = false;
                let count = self.virtual_engine.count;
                let labels = self.space_labels.clone();
                let rules: Vec<(String, WorkspaceTarget)> = self
                    .app_workspaces
                    .iter()
                    .map(|(k, v)| (k.clone(), v.clone()))
                    .collect();

                for (bundle, target) in rules {
                    let Some(new_ws) = target.resolve(count, &labels) else {
                        continue;
                    };
                    if previous_resolved.get(&bundle) == Some(&new_ws) {
                        continue;
                    }
                    let matching_keys: Vec<u64> = self
                        .virtual_engine
                        .all_windows()
                        .into_iter()
                        .filter(|k| {
                            self.window_by_key
                                .get(k)
                                .and_then(|w| w.bundle_id.as_deref())
                                == Some(bundle.as_str())
                        })
                        .collect();
                    for key in matching_keys {
                        if self.virtual_engine.workspace_containing(&key) != Some(new_ws) {
                            let (moved, _) = self.virtual_engine.move_window(&key, new_ws);
                            if moved {
                                if let Some(wid) =
                                    self.window_by_key.get(&key).and_then(|w| w.window_id)
                                {
                                    self.last_workspace_by_window_id.insert(wid, new_ws);
                                }
                                moved_any = true;
                            }
                        }
                    }
                }
                if moved_any {
                    self.suppress_external_focus_until = now + 0.5;
                    self.windows = self
                        .virtual_engine
                        .active_windows()
                        .iter()
                        .filter_map(|k| self.window_by_key.get(k).cloned())
                        .collect();
                    if trusted {
                        self.tile(now, frontmost_key, &mut effects);
                        if let Some(next_key) = self.virtual_engine.active_focused() {
                            if let Some(next_win) = self.window_by_key.get(&next_key).cloned() {
                                self.emit_focus(&next_win, now, &mut effects);
                            }
                        } else if self.windows.is_empty() {
                            self.emit_relinquish_focus(&mut effects);
                        }
                    }
                    self.record_current_session_state();
                }
            }
        }
        self.make_output(effects)
    }

    pub fn virtual_space_entries(&self) -> Vec<SpaceEntry> {
        (0..self.virtual_engine.count)
            .map(|idx| {
                let count = self.virtual_engine.window_count(idx);
                let is_full = self.virtual_engine.layouts[idx].layout_mode == 2 && count > 0;
                SpaceEntry {
                    id: (idx + 1) as u64,
                    is_current: idx == self.virtual_engine.active,
                    is_fullscreen: is_full,
                    window_count: Some(count),
                }
            })
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample_screen() -> ScreenSpec {
        ScreenSpec {
            id: 1,
            full_frame: Rect::new(0.0, 0.0, 1440.0, 900.0),
            visible_frame: Rect::new(0.0, 25.0, 1440.0, 875.0),
        }
    }

    fn candidate(key: u64, wid: u32, pid: i32, bundle: &str, title: &str) -> CandidateWindow {
        CandidateWindow {
            key,
            pid,
            bundle_id: Some(bundle.to_string()),
            window_id: Some(wid),
            title: title.to_string(),
            is_resizable: true,
            frame: Rect::new(100.0, 100.0, 600.0, 400.0),
        }
    }

    #[test]
    fn virtual_workspace_refresh_tile_switch_and_move() {
        let mut cfg = Configuration::default();
        cfg.workspace_mode = "virtual".to_string();
        cfg.workspace_count = 3;
        let mut mgr = ManagerCore::new(&cfg, None);
        let screens = vec![sample_screen()];
        let c1 = candidate(1, 101, 1001, "com.apple.Terminal", "term-1");
        let c2 = candidate(2, 102, 1002, "com.apple.Safari", "web-1");

        let out = mgr.refresh(
            false,
            10.0,
            screens.clone(),
            vec![c1.clone(), c2.clone()],
            &[],
            &[101, 102],
            &[101, 102],
            &[],
            &[],
            true,
            Some(1),
            false,
        );
        assert_eq!(out.active_window_keys, vec![1, 2]);
        assert_eq!(out.observe_window_keys.len(), 2);
        assert_eq!(out.effects.len(), 2);

        // Move focused window (1) to workspace index 1 (Workspace 2)
        let move_out = mgr.move_window_to_workspace(1, 11.0, true, Some(1), &HashMap::new());
        assert_eq!(move_out.active_window_keys, vec![2]);
        // Key 1 should be parked at bottom-right 1x1 pixel of full_frame (1439, 899), key 2 tiled full
        assert!(move_out.effects.iter().any(|e| matches!(
            e,
            WindowEffect::SetPosition { key: 1, x, y } if (*x - 1439.0).abs() < 1e-6 && (*y - 899.0).abs() < 1e-6
        )));
        assert!(move_out
            .effects
            .iter()
            .any(|e| matches!(e, WindowEffect::Focus { key: 2, .. })));

        // Switch to workspace index 1 (Workspace 2)
        let sw_out = mgr.switch_workspace(1, 12.0, true, Some(2), &HashMap::new());
        assert_eq!(sw_out.active_window_keys, vec![1]);
        assert_eq!(sw_out.active_workspace, 1);
        assert!(sw_out
            .effects
            .iter()
            .any(|e| matches!(e, WindowEffect::Focus { key: 1, .. })));
    }

    #[test]
    fn gap_changes_retile_all_layouts_without_moving_floating_windows() {
        for workspace_mode in ["native", "virtual"] {
            let mut cfg = Configuration {
                workspace_mode: workspace_mode.to_string(),
                ..Configuration::default()
            };
            let mut mgr = ManagerCore::new(&cfg, None);
            let candidates = vec![
                candidate(1, 101, 1001, "com.apple.Terminal", "term-1"),
                candidate(2, 102, 1002, "com.apple.Safari", "web-1"),
                candidate(3, 103, 1003, "com.example.Float", "floating"),
            ];
            mgr.refresh(
                false,
                10.0,
                vec![sample_screen()],
                candidates,
                &[],
                &[101, 102, 103],
                &[101, 102, 103],
                &[],
                &[],
                true,
                Some(1),
                false,
            );
            mgr.floating.insert(3);
            let mut effects = Vec::new();
            mgr.tile(11.0, Some(1), &mut effects);

            // A one-point gap must resize the master even when its edge moves by just one point.
            cfg.inner_gap = 1.0;
            let live_frames = mgr
                .window_by_key
                .iter()
                .map(|(k, w)| (*k, w.frame))
                .collect();
            mgr.apply_config(&cfg, 12.0, true, Some(1), &live_frames);
            effects.clear();
            mgr.tile(13.0, Some(1), &mut effects);
            assert!(effects.iter().any(|e| matches!(e,
                WindowEffect::SetFrame { key: 1, rect } if rect.w == 719.0)));
            let left = mgr.window_by_key[&1].frame;
            let right = mgr.window_by_key[&2].frame;
            assert_eq!(right.x - left.max_x(), 1.0);

            cfg.outer_gap = 12.0;
            cfg.inner_gap = 8.0;
            let live_frames = mgr
                .window_by_key
                .iter()
                .map(|(k, w)| (*k, w.frame))
                .collect();
            mgr.apply_config(&cfg, 14.0, true, Some(1), &live_frames);
            let area = sample_screen().visible_frame;
            let inset = inset_area(area, 12.0);
            for mode in 0..=2 {
                mgr.set_current_layout_mode(mode);
                effects.clear();
                mgr.tile(15.0 + mode as f64, Some(1), &mut effects);
                assert!(!effects.iter().any(|e| matches!(
                    e,
                    WindowEffect::SetFrame { key: 3, .. }
                        | WindowEffect::SetPosition { key: 3, .. }
                )));
                let first = mgr.window_by_key[&1].frame;
                let second = mgr.window_by_key[&2].frame;
                assert_eq!((first.x, first.y), (inset.x, inset.y));
                match mode {
                    0 => assert_eq!(second.x - first.max_x(), 8.0),
                    1 => assert_eq!(second.y - first.max_y(), 8.0),
                    _ => assert_eq!((first, second), (inset, inset)),
                }
            }
        }
    }

    #[test]
    fn keybindings_cycle_layout_float_and_pause() {
        let cfg = Configuration::default();
        let mut mgr = ManagerCore::new(&cfg, None);
        let screens = vec![sample_screen()];
        let c1 = candidate(1, 101, 1001, "com.apple.Terminal", "term-1");
        let c2 = candidate(2, 102, 1002, "com.apple.Terminal", "term-2");

        mgr.refresh(
            false,
            10.0,
            screens,
            vec![c1, c2],
            &[],
            &[101, 102],
            &[101, 102],
            &[],
            &[],
            true,
            Some(1),
            false,
        );

        // Space cycles Tall -> Mirror -> Full
        let out_m = mgr.handle_key(KVK_SPACE, false, 11.0, true, Some(1), &HashMap::new());
        assert_eq!(out_m.layout_name, "Mirror");
        let out_f = mgr.handle_key(KVK_SPACE, false, 12.0, true, Some(1), &HashMap::new());
        assert_eq!(out_f.layout_name, "Full");

        // Toggle float on window 1 with T -> restores saved pre-tiled frame (600x400)
        let out_t = mgr.handle_key(KVK_ANSI_T, false, 13.0, true, Some(1), &HashMap::new());
        assert!(out_t.effects.iter().any(|e| matches!(
            e,
            WindowEffect::SetFrame { key: 1, rect } if (rect.w - 600.0).abs() < 1e-6 && (rect.h - 400.0).abs() < 1e-6
        )));

        // Toggle pause with P
        let out_p = mgr.handle_key(KVK_ANSI_P, false, 14.0, true, Some(1), &HashMap::new());
        assert_eq!(out_p.paused, true);
        assert_eq!(out_p.paused_toggled, Some(true));
        assert_eq!(out_p.layout_name, "Full");
    }
}
