use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashMap, HashSet};
use std::hash::Hash;
use std::os::unix::fs::OpenOptionsExt;
use std::path::Path;

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkspaceLayoutState {
    pub layout_mode: i32,
    pub ratio: f64,
    pub masters: usize,
}

impl Default for WorkspaceLayoutState {
    fn default() -> Self {
        Self {
            layout_mode: 0,
            ratio: 0.5,
            masters: 1,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct PersistedWindowRect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
pub struct PersistedWorkspaceSession {
    #[serde(rename = "activeWorkspace")]
    pub active_workspace: usize,
    pub layouts: Vec<WorkspaceLayoutState>,
    #[serde(rename = "workspaceWindowIDs")]
    pub workspace_window_ids: Vec<Vec<u32>>,
    #[serde(rename = "focusedWindowIDByWorkspace")]
    pub focused_window_id_by_workspace: BTreeMap<String, u32>,
    #[serde(rename = "floatingWindowIDs")]
    pub floating_window_ids: Vec<u32>,
    #[serde(rename = "savedFramesByWindowID")]
    pub saved_frames_by_window_id: BTreeMap<String, PersistedWindowRect>,
}

impl PersistedWorkspaceSession {
    pub fn new(
        active_workspace: usize,
        layouts: Vec<WorkspaceLayoutState>,
        workspace_window_ids: Vec<Vec<u32>>,
        focused_by_workspace: &HashMap<usize, u32>,
        floating_window_ids: &[u32],
        saved_frames: &HashMap<u32, PersistedWindowRect>,
    ) -> Self {
        let mut focus_out = BTreeMap::new();
        for (&ws, &wid) in focused_by_workspace {
            focus_out.insert(ws.to_string(), wid);
        }
        let mut sorted_floating = floating_window_ids.to_vec();
        sorted_floating.sort_unstable();
        sorted_floating.dedup();
        let mut frames_out = BTreeMap::new();
        for (&wid, &rect) in saved_frames {
            frames_out.insert(wid.to_string(), rect);
        }
        Self {
            active_workspace,
            layouts,
            workspace_window_ids,
            focused_window_id_by_workspace: focus_out,
            floating_window_ids: sorted_floating,
            saved_frames_by_window_id: frames_out,
        }
    }

    pub fn focused_by_workspace_map(&self) -> HashMap<usize, u32> {
        let mut out = HashMap::new();
        for (k, &wid) in &self.focused_window_id_by_workspace {
            if let Ok(ws) = k.parse::<usize>() {
                out.insert(ws, wid);
            }
        }
        out
    }

    pub fn saved_frames_map(&self) -> HashMap<u32, PersistedWindowRect> {
        let mut out = HashMap::new();
        for (k, &rect) in &self.saved_frames_by_window_id {
            if let Ok(wid) = k.parse::<u32>() {
                out.insert(wid, rect);
            }
        }
        out
    }

    pub fn load_from_path(path: &Path) -> Option<Self> {
        let bytes = std::fs::read(path).ok()?;
        serde_json::from_slice(&bytes).ok()
    }

    pub fn save_to_path(&self, path: &Path) -> Result<(), String> {
        let dir = path.parent().unwrap_or_else(|| Path::new("."));
        std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
        let data = serde_json::to_vec(self).map_err(|e| e.to_string())?;
        write_atomic_0600(&data, path)
    }
}

pub fn write_atomic_0600(data: &[u8], destination: &Path) -> Result<(), String> {
    use std::io::Write;
    let dir = destination.parent().unwrap_or_else(|| Path::new("."));
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let tmp = dir.join(format!(".talus-tmp-{}-{}", std::process::id(), nanos));
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(&tmp)
        .map_err(|e| e.to_string())?;
    if let Err(e) = file.write_all(data) {
        let _ = std::fs::remove_file(&tmp);
        return Err(e.to_string());
    }
    drop(file);
    std::fs::rename(&tmp, destination).map_err(|e| {
        let _ = std::fs::remove_file(&tmp);
        e.to_string()
    })
}

/// Pure XMonad-inspired virtual workspace state machine.
#[derive(Debug, Clone)]
pub struct VirtualWorkspaceEngine<ID: Eq + Hash + Clone> {
    pub count: usize,
    pub active: usize,
    pub stacks: Vec<Vec<ID>>,
    pub focused_by_workspace: HashMap<usize, ID>,
    pub layouts: Vec<WorkspaceLayoutState>,
    default_ratio: f64,
    default_masters: usize,
}

impl<ID: Eq + Hash + Clone> VirtualWorkspaceEngine<ID> {
    pub fn new(count: usize, default_ratio: f64, default_masters: usize) -> Self {
        let clamped = count.clamp(1, 9);
        Self {
            count: clamped,
            active: 0,
            stacks: vec![Vec::new(); clamped],
            focused_by_workspace: HashMap::new(),
            layouts: vec![
                WorkspaceLayoutState {
                    layout_mode: 0,
                    ratio: default_ratio,
                    masters: default_masters,
                };
                clamped
            ],
            default_ratio,
            default_masters,
        }
    }

    pub fn active_layout(&self) -> WorkspaceLayoutState {
        self.layouts[self.active]
    }

    pub fn active_layout_mut(&mut self) -> &mut WorkspaceLayoutState {
        &mut self.layouts[self.active]
    }

    pub fn active_windows(&self) -> &[ID] {
        &self.stacks[self.active]
    }

    pub fn inactive_windows(&self) -> Vec<ID> {
        let mut out = Vec::new();
        for idx in 0..self.count {
            if idx != self.active {
                out.extend(self.stacks[idx].iter().cloned());
            }
        }
        out
    }

    pub fn all_windows(&self) -> Vec<ID> {
        self.stacks.iter().flatten().cloned().collect()
    }

    pub fn active_focused(&self) -> Option<ID> {
        if let Some(f) = self.focused_by_workspace.get(&self.active) {
            if self.stacks[self.active].contains(f) {
                return Some(f.clone());
            }
        }
        self.stacks[self.active].first().cloned()
    }

    pub fn workspace_containing(&self, id: &ID) -> Option<usize> {
        self.stacks.iter().position(|s| s.contains(id))
    }

    pub fn window_count(&self, workspace: usize) -> usize {
        self.stacks.get(workspace).map(|s| s.len()).unwrap_or(0)
    }

    pub fn restore_layouts_and_active(
        &mut self,
        restored_active: usize,
        restored_layouts: &[WorkspaceLayoutState],
    ) {
        self.active = restored_active.min(self.count.saturating_sub(1));
        for idx in 0..self.count.min(restored_layouts.len()) {
            let src = restored_layouts[idx];
            let mode = if (0..=2).contains(&src.layout_mode) {
                src.layout_mode
            } else {
                0
            };
            let clamped_ratio = src.ratio.clamp(0.2, 0.8);
            let clamped_masters = src.masters.clamp(1, 20);
            self.layouts[idx] = WorkspaceLayoutState {
                layout_mode: mode,
                ratio: clamped_ratio,
                masters: clamped_masters,
            };
        }
    }

    pub fn seed_from_current_desktop<FAssign, FRank, FFocus>(
        &mut self,
        ordered_windows: &[ID],
        focused: Option<&ID>,
        assigned_workspace: FAssign,
        preferred_order_rank: FRank,
        preferred_focus_for_workspace: FFocus,
    ) where
        FAssign: Fn(&ID) -> Option<usize>,
        FRank: Fn(&ID) -> Option<usize>,
        FFocus: Fn(usize, &[ID]) -> Option<ID>,
    {
        let mut seen = HashSet::new();
        let unique: Vec<ID> = ordered_windows
            .iter()
            .filter(|id| seen.insert((*id).clone()))
            .cloned()
            .collect();
        for s in &mut self.stacks {
            s.clear();
        }
        self.focused_by_workspace.clear();

        for id in unique {
            let ws = assigned_workspace(&id)
                .filter(|&w| w < self.count)
                .unwrap_or(self.active);
            self.stacks[ws].push(id);
        }

        for ws in 0..self.count {
            if self.stacks[ws].len() > 1 {
                let mut indexed: Vec<(usize, ID)> =
                    self.stacks[ws].drain(..).enumerate().collect();
                indexed.sort_by(|(idx1, elem1), (idx2, elem2)| {
                    let r1 = preferred_order_rank(elem1).unwrap_or(usize::MAX);
                    let r2 = preferred_order_rank(elem2).unwrap_or(usize::MAX);
                    r1.cmp(&r2).then_with(|| idx1.cmp(idx2))
                });
                self.stacks[ws] = indexed.into_iter().map(|(_, e)| e).collect();
            }
        }

        for ws in 0..self.count {
            if !self.stacks[ws].is_empty() {
                if ws == self.active {
                    if let Some(f) = focused {
                        if self.stacks[ws].contains(f) {
                            self.focused_by_workspace.insert(ws, f.clone());
                            continue;
                        }
                    }
                }
                if let Some(pref) = preferred_focus_for_workspace(ws, &self.stacks[ws]) {
                    if self.stacks[ws].contains(&pref) {
                        self.focused_by_workspace.insert(ws, pref);
                        continue;
                    }
                }
                if let Some(f) = focused {
                    if self.stacks[ws].contains(f) {
                        self.focused_by_workspace.insert(ws, f.clone());
                        continue;
                    }
                }
                if let Some(first) = self.stacks[ws].first().cloned() {
                    self.focused_by_workspace.insert(ws, first);
                }
            }
        }
    }

    pub fn update_defaults(&mut self, ratio: f64, masters: usize) {
        let ratio_changed = (ratio - self.default_ratio).abs() > 0.0001;
        let masters_changed = masters != self.default_masters;
        for idx in 0..self.count {
            if ratio_changed && (self.layouts[idx].ratio - self.default_ratio).abs() <= 0.0001 {
                self.layouts[idx].ratio = ratio;
            }
            if masters_changed && self.layouts[idx].masters == self.default_masters {
                self.layouts[idx].masters = masters;
            }
        }
        self.default_ratio = ratio;
        self.default_masters = masters;
    }

    pub fn resize_count(&mut self, requested_count: usize) {
        let new_count = requested_count.clamp(1, 9);
        if new_count == self.count {
            return;
        }
        if new_count > self.count {
            for _ in self.count..new_count {
                self.stacks.push(Vec::new());
                self.layouts.push(WorkspaceLayoutState {
                    layout_mode: 0,
                    ratio: self.default_ratio,
                    masters: self.default_masters,
                });
            }
        } else {
            let last_idx = new_count - 1;
            for overflow_idx in new_count..self.count {
                let overflow_items = std::mem::take(&mut self.stacks[overflow_idx]);
                for id in overflow_items {
                    if !self.stacks[last_idx].contains(&id) {
                        self.stacks[last_idx].push(id);
                    }
                }
                self.focused_by_workspace.remove(&overflow_idx);
            }
            self.stacks.truncate(new_count);
            self.layouts.truncate(new_count);
            if self.active >= new_count {
                self.active = last_idx;
            }
            let valid_last_focus = self
                .focused_by_workspace
                .get(&last_idx)
                .map(|f| self.stacks[last_idx].contains(f))
                .unwrap_or(false);
            if !valid_last_focus {
                if let Some(first) = self.stacks[last_idx].first().cloned() {
                    self.focused_by_workspace.insert(last_idx, first);
                } else {
                    self.focused_by_workspace.remove(&last_idx);
                }
            }
        }
        self.count = new_count;
    }

    pub fn reconcile<FAssign, FCanInsert>(
        &mut self,
        discovered: &[ID],
        currently_focused: Option<&ID>,
        assigned_workspace: FAssign,
        can_insert_before_focus: FCanInsert,
    ) -> (bool, Vec<ID>)
    where
        FAssign: Fn(&ID) -> Option<usize>,
        FCanInsert: Fn(&ID, &ID) -> bool,
    {
        let before_stacks = self.stacks.clone();
        let mut auto_shifted = Vec::new();
        let mut unique_discovered = Vec::new();
        let mut seen_discovered = HashSet::new();
        for id in discovered {
            if seen_discovered.insert(id.clone()) {
                unique_discovered.push(id.clone());
            }
        }

        // 1. Prune closed windows while picking neighbor focus
        for ws in 0..self.count {
            let old_stack = &self.stacks[ws];
            let new_stack: Vec<ID> = old_stack
                .iter()
                .filter(|id| seen_discovered.contains(*id))
                .cloned()
                .collect();
            if new_stack != *old_stack {
                if let Some(old_focus) = self.focused_by_workspace.get(&ws).cloned() {
                    if !new_stack.contains(&old_focus) {
                        if let Some(old_idx) = old_stack.iter().position(|x| *x == old_focus) {
                            if !new_stack.is_empty() {
                                let mut replacement = None;
                                for probe in (old_idx + 1)..old_stack.len() {
                                    if seen_discovered.contains(&old_stack[probe]) {
                                        replacement = Some(old_stack[probe].clone());
                                        break;
                                    }
                                }
                                if replacement.is_none() {
                                    for probe in (0..old_idx).rev() {
                                        if seen_discovered.contains(&old_stack[probe]) {
                                            replacement = Some(old_stack[probe].clone());
                                            break;
                                        }
                                    }
                                }
                                if let Some(rep) = replacement.or_else(|| new_stack.first().cloned())
                                {
                                    self.focused_by_workspace.insert(ws, rep);
                                }
                            } else {
                                self.focused_by_workspace.remove(&ws);
                            }
                        } else if let Some(first) = new_stack.first().cloned() {
                            self.focused_by_workspace.insert(ws, first);
                        } else {
                            self.focused_by_workspace.remove(&ws);
                        }
                    }
                }
                self.stacks[ws] = new_stack;
            }
        }

        // 2. Track all currently assigned windows
        let mut assigned: HashSet<ID> = self.stacks.iter().flatten().cloned().collect();

        if let Some(cf) = currently_focused {
            if self.stacks[self.active].contains(cf) {
                self.focused_by_workspace.insert(self.active, cf.clone());
            }
        }

        // 3. Route newly discovered windows
        let anchor_focus = self.active_focused();
        for id in unique_discovered {
            if assigned.contains(&id) {
                continue;
            }
            assigned.insert(id.clone());
            let target_ws = assigned_workspace(&id)
                .filter(|&w| w < self.count)
                .unwrap_or(self.active);
            if target_ws != self.active {
                self.stacks[target_ws].insert(0, id.clone());
                self.focused_by_workspace.insert(target_ws, id.clone());
                auto_shifted.push(id);
            } else {
                let inserted_at_anchor = if let Some(ref anchor) = anchor_focus {
                    if let Some(anchor_idx) =
                        self.stacks[self.active].iter().position(|x| x == anchor)
                    {
                        if can_insert_before_focus(&id, anchor) {
                            self.stacks[self.active].insert(anchor_idx, id.clone());
                            true
                        } else {
                            false
                        }
                    } else {
                        false
                    }
                } else {
                    false
                };
                if !inserted_at_anchor {
                    self.stacks[self.active].push(id.clone());
                }
                if currently_focused == Some(&id)
                    || !self.focused_by_workspace.contains_key(&self.active)
                {
                    self.focused_by_workspace.insert(self.active, id);
                }
            }
        }

        // 4. Normalize active workspace focus
        let valid_active_focus = self
            .focused_by_workspace
            .get(&self.active)
            .map(|f| self.stacks[self.active].contains(f))
            .unwrap_or(false);
        if !valid_active_focus {
            if let Some(first) = self.stacks[self.active].first().cloned() {
                self.focused_by_workspace.insert(self.active, first);
            } else {
                self.focused_by_workspace.remove(&self.active);
            }
        }

        (self.stacks != before_stacks, auto_shifted)
    }

    pub fn switch_to(&mut self, target: usize) -> bool {
        if target >= self.count || target == self.active {
            return false;
        }
        self.active = target;
        let valid = self
            .focused_by_workspace
            .get(&self.active)
            .map(|f| self.stacks[self.active].contains(f))
            .unwrap_or(false);
        if !valid {
            if let Some(first) = self.stacks[self.active].first().cloned() {
                self.focused_by_workspace.insert(self.active, first);
            } else {
                self.focused_by_workspace.remove(&self.active);
            }
        }
        true
    }

    pub fn move_window(&mut self, id: &ID, target: usize) -> (bool, Option<ID>) {
        if target >= self.count {
            return (false, self.active_focused());
        }
        let Some(source) = self.workspace_containing(id) else {
            return (false, self.active_focused());
        };
        if source == target {
            return (false, self.active_focused());
        }
        let Some(old_idx) = self.stacks[source].iter().position(|x| x == id) else {
            return (false, self.active_focused());
        };

        let removed = self.stacks[source].remove(old_idx);
        if self.focused_by_workspace.get(&source) == Some(&removed) {
            if self.stacks[source].is_empty() {
                self.focused_by_workspace.remove(&source);
            } else {
                let next_idx = old_idx.min(self.stacks[source].len() - 1);
                let next_focus = self.stacks[source][next_idx].clone();
                self.focused_by_workspace.insert(source, next_focus);
            }
        }

        self.stacks[target].retain(|x| x != &removed);
        self.stacks[target].insert(0, removed.clone());
        self.focused_by_workspace.insert(target, removed);

        (true, self.active_focused())
    }

    pub fn handle_external_focus(&mut self, id: &ID) -> Option<usize> {
        let ws = self.workspace_containing(id)?;
        self.focused_by_workspace.insert(ws, id.clone());
        if ws != self.active {
            self.active = ws;
            Some(ws)
        } else {
            None
        }
    }

    pub fn set_active_focus(&mut self, id: Option<ID>) {
        if let Some(val) = id {
            if self.stacks[self.active].contains(&val) {
                self.focused_by_workspace.insert(self.active, val);
            }
        } else if self.stacks[self.active].is_empty() {
            self.focused_by_workspace.remove(&self.active);
        }
    }

    pub fn replace_active_stack(&mut self, new_order: &[ID]) {
        let mut seen = HashSet::new();
        let current_set: HashSet<ID> = self.stacks[self.active].iter().cloned().collect();
        let mut filtered: Vec<ID> = new_order
            .iter()
            .filter(|id| current_set.contains(*id) && seen.insert((*id).clone()))
            .cloned()
            .collect();
        for id in &self.stacks[self.active] {
            if seen.insert(id.clone()) {
                filtered.push(id.clone());
            }
        }
        self.stacks[self.active] = filtered;
        let valid = self
            .focused_by_workspace
            .get(&self.active)
            .map(|f| self.stacks[self.active].contains(f))
            .unwrap_or(false);
        if !valid {
            if let Some(first) = self.stacks[self.active].first().cloned() {
                self.focused_by_workspace.insert(self.active, first);
            } else {
                self.focused_by_workspace.remove(&self.active);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_virtual_workspace_engine_lifecycle() {
        let mut engine = VirtualWorkspaceEngine::<String>::new(5, 0.52, 1);
        engine.seed_from_current_desktop(
            &["A".to_string(), "B".to_string(), "C".to_string()],
            Some(&"B".to_string()),
            |_| None,
            |_| None,
            |_, _| None,
        );
        assert_eq!(engine.active_windows(), &["A", "B", "C"]);
        assert_eq!(engine.active_focused().as_deref(), Some("B"));

        let (moved, next) = engine.move_window(&"B".to_string(), 2);
        assert!(moved);
        assert_eq!(next.as_deref(), Some("C"));
        assert_eq!(engine.active_windows(), &["A", "C"]);
        assert_eq!(engine.window_count(2), 1);

        assert!(engine.switch_to(2));
        assert_eq!(engine.active_windows(), &["B"]);
        let (changed, shifted) = engine.reconcile(
            &[
                "C".to_string(),
                "B".to_string(),
                "A".to_string(),
                "D".to_string(),
            ],
            Some(&"D".to_string()),
            |_| None,
            |_, _| true,
        );
        assert!(changed && shifted.is_empty());
        assert_eq!(engine.active_windows(), &["D", "B"]);
        assert_eq!(engine.active_focused().as_deref(), Some("D"));
    }
}
