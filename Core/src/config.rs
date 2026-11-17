use serde::{Deserialize, Deserializer, Serialize, Serializer};
use std::collections::{BTreeMap, HashSet};
use std::path::Path;
use toml_edit::{DocumentMut, Item, Table, Value};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ConfigResolution {
    pub load_path: String,
    pub save_path: String,
    pub migrated_from_json: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum WorkspaceTarget {
    Index(i32),
    Label(String),
}

impl Serialize for WorkspaceTarget {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        match self {
            WorkspaceTarget::Index(n) => serializer.serialize_i32(*n),
            WorkspaceTarget::Label(s) => serializer.serialize_str(s),
        }
    }
}

impl<'de> Deserialize<'de> for WorkspaceTarget {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let val = serde_json::Value::deserialize(deserializer)?;
        if let Some(n) = val.as_i64() {
            Ok(WorkspaceTarget::Index(n as i32))
        } else if let Some(s) = val.as_str() {
            Ok(WorkspaceTarget::Label(s.to_string()))
        } else {
            Err(serde::de::Error::custom(
                "Expected workspace number (1..9) or label string",
            ))
        }
    }
}

impl WorkspaceTarget {
    pub fn resolve(&self, workspace_count: usize, space_labels: &[String]) -> Option<usize> {
        match self {
            WorkspaceTarget::Index(n) => {
                if *n >= 1 && (*n as usize) <= workspace_count {
                    Some((*n as usize) - 1)
                } else {
                    None
                }
            }
            WorkspaceTarget::Label(name) => {
                if let Some(idx) = space_labels.iter().position(|s| s == name) {
                    if idx < workspace_count {
                        return Some(idx);
                    }
                }
                if let Ok(n) = name.parse::<usize>() {
                    if n >= 1 && n <= workspace_count {
                        return Some(n - 1);
                    }
                }
                None
            }
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FloatWindowRule {
    pub app: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub titles: Option<Vec<String>>,
    #[serde(alias = "except_titles", skip_serializing_if = "Option::is_none")]
    pub except_titles: Option<Vec<String>>,
}

impl FloatWindowRule {
    pub fn new(
        app: impl Into<String>,
        titles: Option<Vec<String>>,
        except_titles: Option<Vec<String>>,
    ) -> Self {
        Self {
            app: app.into(),
            titles,
            except_titles,
        }
    }

    pub fn matches(&self, bundle_id: Option<&str>, window_title: &str) -> bool {
        let Some(bundle) = bundle_id else {
            return false;
        };
        if bundle != self.app {
            return false;
        }
        let normalized_title = window_title.trim();
        if let Some(ref excepts) = self.except_titles {
            if !excepts.is_empty() {
                for ex in excepts {
                    let target = ex.trim();
                    if Self::matches_glob_or_exact(normalized_title, target) {
                        return false;
                    }
                }
            }
        }
        if let Some(ref titles) = self.titles {
            if !titles.is_empty() {
                return titles.iter().any(|pattern| {
                    let p = pattern.trim();
                    if p.contains('*') {
                        Self::matches_glob(normalized_title, p)
                    } else if p.is_empty() {
                        normalized_title.is_empty()
                    } else {
                        normalized_title
                            .to_lowercase()
                            .contains(&p.to_lowercase())
                    }
                });
            }
        }
        true
    }

    fn matches_glob_or_exact(text: &str, pattern: &str) -> bool {
        if pattern.contains('*') {
            Self::matches_glob(text, pattern)
        } else {
            text == pattern
        }
    }

    fn matches_glob(text: &str, pattern: &str) -> bool {
        let lower_text: Vec<char> = text.to_lowercase().chars().collect();
        let lower_pat: Vec<char> = pattern.to_lowercase().chars().collect();
        let mut ti = 0usize;
        let mut pi = 0usize;
        let mut star_idx: Option<usize> = None;
        let mut match_idx = 0usize;

        while ti < lower_text.len() {
            if pi < lower_pat.len() && lower_pat[pi] == lower_text[ti] {
                pi += 1;
                ti += 1;
            } else if pi < lower_pat.len() && lower_pat[pi] == '*' {
                star_idx = Some(pi);
                match_idx = ti;
                pi += 1;
            } else if let Some(s_idx) = star_idx {
                pi = s_idx + 1;
                match_idx += 1;
                ti = match_idx;
            } else {
                return false;
            }
        }
        while pi < lower_pat.len() && lower_pat[pi] == '*' {
            pi += 1;
        }
        pi == lower_pat.len()
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StatusCommand {
    pub name: String,
    pub executable: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub arguments: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub interval: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub timeout: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub markup: Option<bool>,
    #[serde(alias = "on_change", skip_serializing_if = "Option::is_none")]
    pub on_change: Option<bool>,
}

impl StatusCommand {
    pub fn validate(&self) -> Result<(), String> {
        const RESERVED: &[&str] = &[
            "spaces",
            "layout",
            "title",
            "count",
            "custom",
            "label",
            "index",
            "fullscreen",
            "occupied",
            "icon",
        ];
        let valid_name = !self.name.is_empty()
            && self.name.len() <= 32
            && self
                .name
                .chars()
                .next()
                .map(|c| c.is_ascii_alphabetic())
                .unwrap_or(false)
            && self
                .name
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-');
        if !valid_name || RESERVED.contains(&self.name.as_str()) {
            return Err(
                "invalid status command: check name, executable, arguments, interval and timeout"
                    .to_string(),
            );
        }
        if !self.executable.starts_with('/') || self.executable.len() > 1024 {
            return Err(
                "invalid status command: check name, executable, arguments, interval and timeout"
                    .to_string(),
            );
        }
        if let Some(ref args) = self.arguments {
            if args.len() > 32 || args.iter().any(|a| a.len() > 1024) {
                return Err(
                    "invalid status command: check name, executable, arguments, interval and timeout"
                        .to_string(),
                );
            }
        }
        let interval = self.interval.unwrap_or(10.0);
        let timeout = self.timeout.unwrap_or(2.0);
        if !(1.0..=3600.0).contains(&interval) || !(0.1..=10.0).contains(&timeout) {
            return Err(
                "invalid status command: check name, executable, arguments, interval and timeout"
                    .to_string(),
            );
        }
        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Configuration {
    pub modifiers: Vec<String>,
    pub workspace_mode: String,
    pub workspace_count: usize,
    pub master_ratio: f64,
    pub ratio_step: f64,
    pub master_count: usize,
    pub outer_gap: f64,
    pub inner_gap: f64,
    pub ignore_apps: Vec<String>,
    pub app_workspaces: BTreeMap<String, WorkspaceTarget>,
    pub float_windows: Vec<FloatWindowRule>,
    pub status_format: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub status_template: Option<String>,
    pub status_show_icon: bool,
    pub workspace_current: String,
    pub workspace_other: String,
    pub status_fonts: Vec<String>,
    pub status_font_size: f64,
    pub status_commands: Vec<StatusCommand>,
    pub space_labels: Vec<String>,
    pub workspace_icons: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub status_text_file: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub status_state_file: Option<String>,
}

impl Default for Configuration {
    fn default() -> Self {
        Self {
            modifiers: vec!["control".to_string(), "option".to_string()],
            workspace_mode: "native".to_string(),
            workspace_count: 5,
            master_ratio: 0.5,
            ratio_step: 0.03,
            master_count: 1,
            outer_gap: 0.0,
            inner_gap: 0.0,
            ignore_apps: Vec::new(),
            app_workspaces: BTreeMap::new(),
            float_windows: Vec::new(),
            status_format: "{spaces}  {layout}".to_string(),
            status_template: None,
            status_show_icon: true,
            workspace_current: "<fc=#10201E,#89CFC2> %label%%fullscreen% </fc>".to_string(),
            workspace_other: "%label%%fullscreen%".to_string(),
            status_fonts: Vec::new(),
            status_font_size: 11.5,
            status_commands: Vec::new(),
            space_labels: Vec::new(),
            workspace_icons: Vec::new(),
            status_text_file: None,
            status_state_file: None,
        }
    }
}

pub fn expand_tilde(path: &str, home_dir: Option<&str>) -> String {
    if path == "~" || path.starts_with("~/") {
        let home = home_dir
            .map(|s| s.to_string())
            .or_else(|| std::env::var("HOME").ok())
            .unwrap_or_default();
        if !home.is_empty() {
            if path == "~" {
                return home;
            }
            return format!("{}{}", home.trim_end_matches('/'), &path[1..]);
        }
    }
    path.to_string()
}

fn normalize_lexical_path(path: &str) -> String {
    let expanded = expand_tilde(path, None);
    let is_abs = expanded.starts_with('/');
    let mut parts: Vec<&str> = Vec::new();
    for comp in expanded.split('/') {
        match comp {
            "" | "." => {}
            ".." => {
                parts.pop();
            }
            other => parts.push(other),
        }
    }
    if is_abs {
        format!("/{}", parts.join("/"))
    } else {
        parts.join("/")
    }
}

impl Configuration {
    pub fn validate(&self) -> Result<(), String> {
        let allowed: HashSet<&str> = ["control", "option", "command"].into_iter().collect();
        let unique_mods: HashSet<&str> = self.modifiers.iter().map(|s| s.as_str()).collect();
        if self.modifiers.is_empty()
            || unique_mods.len() != self.modifiers.len()
            || !unique_mods.is_subset(&allowed)
        {
            return Err("modifiers must be distinct control, option or command names".to_string());
        }
        if self.workspace_mode != "native" && self.workspace_mode != "virtual" {
            return Err("workspaceMode must be 'native' or 'virtual'".to_string());
        }
        if !(1..=9).contains(&self.workspace_count) {
            return Err("workspaceCount must be between 1 and 9".to_string());
        }
        if self.app_workspaces.len() > 64 {
            return Err(
                "appWorkspaces entries must map non-empty bundle IDs to workspace 1..9 or a valid label"
                    .to_string(),
            );
        }
        for (bundle, target) in &self.app_workspaces {
            let trimmed = bundle.trim();
            if trimmed.is_empty() || bundle != trimmed || bundle.chars().count() > 200 {
                return Err(
                    "appWorkspaces entries must map non-empty bundle IDs to workspace 1..9 or a valid label"
                        .to_string(),
                );
            }
            match target {
                WorkspaceTarget::Index(n) => {
                    if !(1..=9).contains(n) {
                        return Err(
                            "appWorkspaces entries must map non-empty bundle IDs to workspace 1..9 or a valid label"
                                .to_string(),
                        );
                    }
                }
                WorkspaceTarget::Label(s) => {
                    if s.is_empty() || s.chars().count() > 16 {
                        return Err(
                            "appWorkspaces entries must map non-empty bundle IDs to workspace 1..9 or a valid label"
                                .to_string(),
                        );
                    }
                }
            }
        }
        if self.float_windows.len() > 64 {
            return Err(
                "floatWindows entries must specify a non-empty app bundle ID and at most 32 title patterns"
                    .to_string(),
            );
        }
        for rule in &self.float_windows {
            let trimmed_app = rule.app.trim();
            if trimmed_app.is_empty() || rule.app != trimmed_app || rule.app.chars().count() > 200 {
                return Err(
                    "floatWindows entries must specify a non-empty app bundle ID and at most 32 title patterns"
                        .to_string(),
                );
            }
            if let Some(ref titles) = rule.titles {
                if titles.len() > 32 || titles.iter().any(|t| t.chars().count() > 200) {
                    return Err(
                        "floatWindows entries must specify a non-empty app bundle ID and at most 32 title patterns"
                            .to_string(),
                    );
                }
            }
            if let Some(ref except_titles) = rule.except_titles {
                if except_titles.len() > 32
                    || except_titles.iter().any(|t| t.chars().count() > 200)
                {
                    return Err(
                        "floatWindows entries must specify a non-empty app bundle ID and at most 32 title patterns"
                            .to_string(),
                    );
                }
            }
        }
        if !(0.2..=0.8).contains(&self.master_ratio) {
            return Err("masterRatio must be between 0.2 and 0.8".to_string());
        }
        if !(self.ratio_step > 0.0 && self.ratio_step <= 0.2) {
            return Err("ratioStep must be greater than 0 and at most 0.2".to_string());
        }
        let cmd_names: HashSet<&str> = self.status_commands.iter().map(|c| c.name.as_str()).collect();
        let valid_status = self.space_labels.len() <= 32
            && self
                .space_labels
                .iter()
                .all(|s| !s.is_empty() && s.chars().count() <= 16)
            && self.workspace_icons.len() <= 32
            && self
                .workspace_icons
                .iter()
                .all(|s| !s.is_empty() && s.chars().count() <= 64)
            && self
                .status_template
                .as_ref()
                .map(|s| s.chars().count())
                .unwrap_or(0)
                <= 1024
            && self.workspace_current.chars().count() <= 512
            && self.workspace_other.chars().count() <= 512
            && self.status_fonts.len() <= 16
            && self
                .status_fonts
                .iter()
                .all(|s| !s.is_empty() && s.chars().count() <= 100)
            && (8.0..=14.0).contains(&self.status_font_size)
            && self.status_commands.len() <= 16
            && cmd_names.len() == self.status_commands.len();
        if !valid_status {
            return Err("invalid status template, workspace format, labels or fonts".to_string());
        }
        for cmd in &self.status_commands {
            cmd.validate()?;
        }
        if self.status_format.chars().count() > 160 {
            return Err("invalid status template, workspace format, labels or fonts".to_string());
        }
        if let (Some(ref input), Some(ref output)) =
            (&self.status_text_file, &self.status_state_file)
        {
            if !input.is_empty() && !output.is_empty() {
                if normalize_lexical_path(input) == normalize_lexical_path(output) {
                    return Err(
                        "statusTextFile and statusStateFile must be different files".to_string()
                    );
                }
            }
        }
        if !(1..=20).contains(&self.master_count) {
            return Err("masterCount must be between 1 and 20".to_string());
        }
        if !(0.0..=64.0).contains(&self.outer_gap) || !(0.0..=64.0).contains(&self.inner_gap) {
            return Err("outerGap and innerGap must be between 0 and 64".to_string());
        }
        Ok(())
    }

    pub fn resolve_paths<F: Fn(&str) -> bool>(
        home_directory: &str,
        talus_config_env: Option<&str>,
        file_exists: F,
    ) -> ConfigResolution {
        if let Some(custom) = talus_config_env {
            if !custom.is_empty() {
                let expanded = expand_tilde(custom, Some(home_directory));
                return ConfigResolution {
                    load_path: expanded.clone(),
                    save_path: expanded,
                    migrated_from_json: false,
                };
            }
        }
        let home = home_directory.trim_end_matches('/');
        let dotfile = format!("{}/.talus.toml", home);
        let xdg = format!("{}/.config/talus/config.toml", home);
        let support_toml = format!("{}/Library/Application Support/Talus/config.toml", home);
        let support_json = format!("{}/Library/Application Support/Talus/config.json", home);

        if file_exists(&dotfile) {
            return ConfigResolution {
                load_path: dotfile.clone(),
                save_path: dotfile,
                migrated_from_json: false,
            };
        }
        if file_exists(&xdg) {
            return ConfigResolution {
                load_path: xdg.clone(),
                save_path: xdg,
                migrated_from_json: false,
            };
        }
        if file_exists(&support_toml) {
            return ConfigResolution {
                load_path: support_toml.clone(),
                save_path: support_toml,
                migrated_from_json: false,
            };
        }
        if file_exists(&support_json) {
            return ConfigResolution {
                load_path: support_json,
                save_path: dotfile,
                migrated_from_json: true,
            };
        }
        ConfigResolution {
            load_path: dotfile.clone(),
            save_path: dotfile,
            migrated_from_json: false,
        }
    }

    pub fn load_from_path(path: &Path) -> Result<Self, String> {
        if !path.exists() {
            return Ok(Self::default());
        }
        let bytes = std::fs::read(path).map_err(|e| e.to_string())?;
        let ext = path
            .extension()
            .and_then(|e| e.to_str())
            .unwrap_or("")
            .to_lowercase();
        let config = if ext == "json" {
            serde_json::from_slice::<Configuration>(&bytes).map_err(|e| e.to_string())?
        } else {
            let text = String::from_utf8(bytes)
                .map_err(|_| "configuration file is not valid UTF-8".to_string())?;
            Self::decode_toml(&text)?
        };
        config.validate()?;
        Ok(config)
    }

    pub fn save_to_path(&self, path: &Path) -> Result<(), String> {
        self.validate()?;
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
        }
        let ext = path
            .extension()
            .and_then(|e| e.to_str())
            .unwrap_or("")
            .to_lowercase();
        let data = if ext == "json" {
            serde_json::to_vec_pretty(self).map_err(|e| e.to_string())?
        } else {
            let existing = std::fs::read_to_string(path).ok();
            let text = self.to_toml_preserving_comments(existing.as_deref());
            text.into_bytes()
        };
        let parent = path.parent().unwrap_or_else(|| Path::new("."));
        let tmp = parent.join(format!(
            ".talus-cfg-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_nanos())
                .unwrap_or(0)
        ));
        std::fs::write(&tmp, &data).map_err(|e| e.to_string())?;
        std::fs::rename(&tmp, path).map_err(|e| {
            let _ = std::fs::remove_file(&tmp);
            e.to_string()
        })?;
        Ok(())
    }

    pub fn decode_toml(source: &str) -> Result<Self, String> {
        let doc = source.parse::<DocumentMut>().map_err(|e| e.to_string())?;
        let mut config = Configuration::default();
        let mut seen: HashSet<String> = HashSet::new();

        let mut claim = |canonical: &str, key_label: &str| -> Result<(), String> {
            if !seen.insert(canonical.to_string()) {
                return Err(format!("duplicate setting '{}'", key_label));
            }
            Ok(())
        };

        fn req_string(item: &Item, key: &str) -> Result<String, String> {
            item.as_str()
                .map(|s| s.to_string())
                .ok_or_else(|| format!("'{}' must be a string", key))
        }
        fn req_bool(item: &Item, key: &str) -> Result<bool, String> {
            item.as_bool()
                .ok_or_else(|| format!("'{}' must be true or false", key))
        }
        fn req_int(item: &Item, key: &str) -> Result<i64, String> {
            item.as_integer()
                .ok_or_else(|| format!("'{}' must be an integer", key))
        }
        fn req_double(item: &Item, key: &str) -> Result<f64, String> {
            if let Some(f) = item.as_float() {
                Ok(f)
            } else if let Some(i) = item.as_integer() {
                Ok(i as f64)
            } else {
                Err(format!("'{}' must be a number", key))
            }
        }
        fn req_string_array(item: &Item, key: &str) -> Result<Vec<String>, String> {
            let arr = item
                .as_array()
                .ok_or_else(|| format!("'{}' must be an array of strings", key))?;
            let mut out = Vec::with_capacity(arr.len());
            for elem in arr.iter() {
                let s = elem
                    .as_str()
                    .ok_or_else(|| format!("every item in '{}' must be a string", key))?;
                out.push(s.to_string());
            }
            Ok(out)
        }
        fn parse_command_table(
            table: &dyn toml_edit::TableLike,
            prefix: &str,
        ) -> Result<StatusCommand, String> {
            let mut name: Option<String> = None;
            let mut executable: Option<String> = None;
            let mut arguments: Option<Vec<String>> = None;
            let mut interval: Option<f64> = None;
            let mut timeout: Option<f64> = None;
            let mut markup: Option<bool> = None;
            let mut on_change: Option<bool> = None;
            let mut cmd_seen: HashSet<&str> = HashSet::new();

            for (k, v) in table.iter() {
                match k {
                    "name" => name = Some(req_string(v, &format!("{}.name", prefix))?),
                    "executable" => {
                        executable = Some(req_string(v, &format!("{}.executable", prefix))?)
                    }
                    "arguments" | "args" => {
                        if !cmd_seen.insert("arguments") {
                            return Err(format!("duplicate '{}.{}'", prefix, k));
                        }
                        arguments = Some(req_string_array(v, &format!("{}.{}", prefix, k))?);
                    }
                    "interval" => interval = Some(req_double(v, &format!("{}.interval", prefix))?),
                    "timeout" => timeout = Some(req_double(v, &format!("{}.timeout", prefix))?),
                    "markup" => markup = Some(req_bool(v, &format!("{}.markup", prefix))?),
                    "on_change" | "onChange" => {
                        if !cmd_seen.insert("onChange") {
                            return Err(format!("duplicate '{}.{}'", prefix, k));
                        }
                        on_change = Some(req_bool(v, &format!("{}.{}", prefix, k))?);
                    }
                    _ => return Err(format!("unknown command key '{}.{}'", prefix, k)),
                }
            }
            let final_name = name.ok_or_else(|| format!("'{}' is missing 'name'", prefix))?;
            let final_exec =
                executable.ok_or_else(|| format!("'{}' is missing 'executable'", prefix))?;
            Ok(StatusCommand {
                name: final_name,
                executable: final_exec,
                arguments,
                interval,
                timeout,
                markup,
                on_change,
            })
        }
        fn parse_command_list(item: &Item, key: &str) -> Result<Vec<StatusCommand>, String> {
            if let Some(aot) = item.as_array_of_tables() {
                aot.iter()
                    .enumerate()
                    .map(|(idx, tbl)| parse_command_table(tbl, &format!("{}[{}]", key, idx)))
                    .collect()
            } else if let Some(arr) = item.as_array() {
                arr.iter()
                    .enumerate()
                    .map(|(idx, val)| {
                        let tbl = val
                            .as_inline_table()
                            .ok_or_else(|| format!("'{}[{}]' entry must be a table", key, idx))?;
                        parse_command_table(tbl, &format!("{}[{}]", key, idx))
                    })
                    .collect()
            } else {
                Err(format!("'{}' must be an array of tables", key))
            }
        }
        fn parse_app_workspaces(
            item: &Item,
            key: &str,
        ) -> Result<BTreeMap<String, WorkspaceTarget>, String> {
            let tbl = item.as_table_like().ok_or_else(|| {
                format!(
                    "'{}' must be a table mapping bundle IDs to workspace number or name",
                    key
                )
            })?;
            let mut out = BTreeMap::new();
            for (bundle, raw_target) in tbl.iter() {
                if let Some(n) = raw_target.as_integer() {
                    out.insert(bundle.to_string(), WorkspaceTarget::Index(n as i32));
                } else if let Some(s) = raw_target.as_str() {
                    out.insert(bundle.to_string(), WorkspaceTarget::Label(s.to_string()));
                } else {
                    return Err(format!(
                        "'{}.{}' must be an integer (1..9) or workspace label string",
                        key, bundle
                    ));
                }
            }
            Ok(out)
        }
        fn parse_float_rule_table(
            table: &dyn toml_edit::TableLike,
            prefix: &str,
        ) -> Result<FloatWindowRule, String> {
            let mut app: Option<String> = None;
            let mut titles: Option<Vec<String>> = None;
            let mut except_titles: Option<Vec<String>> = None;
            let mut rule_seen: HashSet<&str> = HashSet::new();
            for (k, v) in table.iter() {
                match k {
                    "app" | "bundle_id" | "bundleId" => {
                        if !rule_seen.insert("app") {
                            return Err(format!("duplicate '{}.{}'", prefix, k));
                        }
                        app = Some(req_string(v, &format!("{}.{}", prefix, k))?);
                    }
                    "titles" => {
                        if !rule_seen.insert("titles") {
                            return Err(format!("duplicate '{}.{}'", prefix, k));
                        }
                        titles = Some(req_string_array(v, &format!("{}.{}", prefix, k))?);
                    }
                    "except_titles" | "exceptTitles" => {
                        if !rule_seen.insert("exceptTitles") {
                            return Err(format!("duplicate '{}.{}'", prefix, k));
                        }
                        except_titles = Some(req_string_array(v, &format!("{}.{}", prefix, k))?);
                    }
                    _ => return Err(format!("unknown float rule key '{}.{}'", prefix, k)),
                }
            }
            let final_app = app.ok_or_else(|| format!("'{}' is missing 'app'", prefix))?;
            Ok(FloatWindowRule {
                app: final_app,
                titles,
                except_titles,
            })
        }
        fn parse_float_rule_list(item: &Item, key: &str) -> Result<Vec<FloatWindowRule>, String> {
            if let Some(aot) = item.as_array_of_tables() {
                aot.iter()
                    .enumerate()
                    .map(|(idx, tbl)| parse_float_rule_table(tbl, &format!("{}[{}]", key, idx)))
                    .collect()
            } else if let Some(arr) = item.as_array() {
                arr.iter()
                    .enumerate()
                    .map(|(idx, val)| {
                        let tbl = val
                            .as_inline_table()
                            .ok_or_else(|| format!("'{}[{}]' entry must be a table", key, idx))?;
                        parse_float_rule_table(tbl, &format!("{}[{}]", key, idx))
                    })
                    .collect()
            } else {
                Err(format!("'{}' must be an array of tables", key))
            }
        }

        for (key, value) in doc.as_table().iter() {
            match key {
                "modifiers" => {
                    claim("modifiers", key)?;
                    config.modifiers = req_string_array(value, key)?;
                }
                "workspace_mode" | "workspaceMode" => {
                    claim("workspaceMode", key)?;
                    config.workspace_mode = req_string(value, key)?;
                }
                "workspace_count" | "workspaceCount" => {
                    claim("workspaceCount", key)?;
                    let n = req_int(value, key)?;
                    config.workspace_count = n.max(0) as usize;
                }
                "master_ratio" | "masterRatio" => {
                    claim("masterRatio", key)?;
                    config.master_ratio = req_double(value, key)?;
                }
                "ratio_step" | "ratioStep" => {
                    claim("ratioStep", key)?;
                    config.ratio_step = req_double(value, key)?;
                }
                "master_count" | "masterCount" => {
                    claim("masterCount", key)?;
                    let n = req_int(value, key)?;
                    config.master_count = n.max(0) as usize;
                }
                "outer_gap" | "outerGap" | "screen_padding" | "screenPadding" | "margin"
                | "padding" => {
                    claim("outerGap", key)?;
                    config.outer_gap = req_double(value, key)?;
                }
                "inner_gap" | "innerGap" | "window_gap" | "windowGap" | "gap" | "spacing" => {
                    claim("innerGap", key)?;
                    config.inner_gap = req_double(value, key)?;
                }
                "ignore_apps" | "ignoreApps" => {
                    claim("ignoreApps", key)?;
                    config.ignore_apps = req_string_array(value, key)?;
                }
                "app_workspaces" | "appWorkspaces" => {
                    claim("appWorkspaces", key)?;
                    config.app_workspaces = parse_app_workspaces(value, key)?;
                }
                "float_windows" | "floatWindows" => {
                    claim("floatWindows", key)?;
                    config.float_windows = parse_float_rule_list(value, key)?;
                }
                "status_format" | "statusFormat" => {
                    claim("statusFormat", key)?;
                    config.status_format = req_string(value, key)?;
                }
                "status_template" | "statusTemplate" => {
                    claim("statusTemplate", key)?;
                    config.status_template = Some(req_string(value, key)?);
                }
                "status_show_icon" | "statusShowIcon" => {
                    claim("statusShowIcon", key)?;
                    config.status_show_icon = req_bool(value, key)?;
                }
                "workspace_current" | "workspaceCurrent" => {
                    claim("workspaceCurrent", key)?;
                    config.workspace_current = req_string(value, key)?;
                }
                "workspace_other" | "workspaceOther" => {
                    claim("workspaceOther", key)?;
                    config.workspace_other = req_string(value, key)?;
                }
                "status_fonts" | "statusFonts" => {
                    claim("statusFonts", key)?;
                    config.status_fonts = req_string_array(value, key)?;
                }
                "status_font_size" | "statusFontSize" => {
                    claim("statusFontSize", key)?;
                    config.status_font_size = req_double(value, key)?;
                }
                "space_labels" | "spaceLabels" => {
                    claim("spaceLabels", key)?;
                    config.space_labels = req_string_array(value, key)?;
                }
                "workspace_icons" | "workspaceIcons" => {
                    claim("workspaceIcons", key)?;
                    config.workspace_icons = req_string_array(value, key)?;
                }
                "status_text_file" | "statusTextFile" => {
                    claim("statusTextFile", key)?;
                    config.status_text_file = Some(req_string(value, key)?);
                }
                "status_state_file" | "statusStateFile" => {
                    claim("statusStateFile", key)?;
                    config.status_state_file = Some(req_string(value, key)?);
                }
                "commands" | "status_commands" | "statusCommands" => {
                    claim("statusCommands", key)?;
                    config.status_commands = parse_command_list(value, key)?;
                }
                "shortcuts" | "keys" => {
                    let sub = value
                        .as_table_like()
                        .ok_or_else(|| format!("'{}' must be a table", key))?;
                    for (sk, sv) in sub.iter() {
                        match sk {
                            "modifiers" => {
                                claim("modifiers", &format!("{}.{}", key, sk))?;
                                config.modifiers =
                                    req_string_array(sv, &format!("{}.{}", key, sk))?;
                            }
                            _ => return Err(format!("unknown key '{}.{}'", key, sk)),
                        }
                    }
                }
                "workspaces" => {
                    let sub = value
                        .as_table_like()
                        .ok_or_else(|| "'workspaces' must be a table".to_string())?;
                    for (sk, sv) in sub.iter() {
                        match sk {
                            "mode" | "workspace_mode" | "workspaceMode" => {
                                claim("workspaceMode", &format!("workspaces.{}", sk))?;
                                config.workspace_mode =
                                    req_string(sv, &format!("workspaces.{}", sk))?;
                            }
                            "count" | "workspace_count" | "workspaceCount" => {
                                claim("workspaceCount", &format!("workspaces.{}", sk))?;
                                let n = req_int(sv, &format!("workspaces.{}", sk))?;
                                config.workspace_count = n.max(0) as usize;
                            }
                            "labels" | "space_labels" | "spaceLabels" => {
                                claim("spaceLabels", &format!("workspaces.{}", sk))?;
                                config.space_labels =
                                    req_string_array(sv, &format!("workspaces.{}", sk))?;
                            }
                            _ => return Err(format!("unknown key 'workspaces.{}'", sk)),
                        }
                    }
                }
                "layout" => {
                    let sub = value
                        .as_table_like()
                        .ok_or_else(|| "'layout' must be a table".to_string())?;
                    for (sk, sv) in sub.iter() {
                        match sk {
                            "master_ratio" | "masterRatio" => {
                                claim("masterRatio", &format!("layout.{}", sk))?;
                                config.master_ratio = req_double(sv, &format!("layout.{}", sk))?;
                            }
                            "ratio_step" | "ratioStep" => {
                                claim("ratioStep", &format!("layout.{}", sk))?;
                                config.ratio_step = req_double(sv, &format!("layout.{}", sk))?;
                            }
                            "master_count" | "masterCount" => {
                                claim("masterCount", &format!("layout.{}", sk))?;
                                let n = req_int(sv, &format!("layout.{}", sk))?;
                                config.master_count = n.max(0) as usize;
                            }
                            "outer_gap" | "outerGap" | "screen_padding" | "screenPadding"
                            | "margin" | "padding" => {
                                claim("outerGap", &format!("layout.{}", sk))?;
                                config.outer_gap = req_double(sv, &format!("layout.{}", sk))?;
                            }
                            "inner_gap" | "innerGap" | "window_gap" | "windowGap" | "gap"
                            | "spacing" => {
                                claim("innerGap", &format!("layout.{}", sk))?;
                                config.inner_gap = req_double(sv, &format!("layout.{}", sk))?;
                            }
                            _ => return Err(format!("unknown key 'layout.{}'", sk)),
                        }
                    }
                }
                "rules" => {
                    let sub = value
                        .as_table_like()
                        .ok_or_else(|| "'rules' must be a table".to_string())?;
                    for (sk, sv) in sub.iter() {
                        match sk {
                            "ignore_apps" | "ignoreApps" => {
                                claim("ignoreApps", &format!("rules.{}", sk))?;
                                config.ignore_apps =
                                    req_string_array(sv, &format!("rules.{}", sk))?;
                            }
                            "app_workspaces" | "appWorkspaces" | "assign" | "workspaces" => {
                                claim("appWorkspaces", &format!("rules.{}", sk))?;
                                config.app_workspaces =
                                    parse_app_workspaces(sv, &format!("rules.{}", sk))?;
                            }
                            "float_windows" | "floatWindows" => {
                                claim("floatWindows", &format!("rules.{}", sk))?;
                                config.float_windows =
                                    parse_float_rule_list(sv, &format!("rules.{}", sk))?;
                            }
                            _ => return Err(format!("unknown key 'rules.{}'", sk)),
                        }
                    }
                }
                "status" => {
                    let sub = value
                        .as_table_like()
                        .ok_or_else(|| "'status' must be a table".to_string())?;
                    for (sk, sv) in sub.iter() {
                        match sk {
                            "show_icon" | "statusShowIcon" => {
                                claim("statusShowIcon", &format!("status.{}", sk))?;
                                config.status_show_icon =
                                    req_bool(sv, &format!("status.{}", sk))?;
                            }
                            "space_labels" | "spaceLabels" => {
                                claim("spaceLabels", &format!("status.{}", sk))?;
                                config.space_labels =
                                    req_string_array(sv, &format!("status.{}", sk))?;
                            }
                            "workspace_icons" | "workspaceIcons" => {
                                claim("workspaceIcons", &format!("status.{}", sk))?;
                                config.workspace_icons =
                                    req_string_array(sv, &format!("status.{}", sk))?;
                            }
                            "template" | "statusTemplate" => {
                                claim("statusTemplate", &format!("status.{}", sk))?;
                                config.status_template =
                                    Some(req_string(sv, &format!("status.{}", sk))?);
                            }
                            "format" | "statusFormat" => {
                                claim("statusFormat", &format!("status.{}", sk))?;
                                config.status_format =
                                    req_string(sv, &format!("status.{}", sk))?;
                            }
                            "workspace_current" | "workspaceCurrent" => {
                                claim("workspaceCurrent", &format!("status.{}", sk))?;
                                config.workspace_current =
                                    req_string(sv, &format!("status.{}", sk))?;
                            }
                            "workspace_other" | "workspaceOther" => {
                                claim("workspaceOther", &format!("status.{}", sk))?;
                                config.workspace_other =
                                    req_string(sv, &format!("status.{}", sk))?;
                            }
                            "fonts" | "statusFonts" => {
                                claim("statusFonts", &format!("status.{}", sk))?;
                                config.status_fonts =
                                    req_string_array(sv, &format!("status.{}", sk))?;
                            }
                            "font_size" | "statusFontSize" => {
                                claim("statusFontSize", &format!("status.{}", sk))?;
                                config.status_font_size =
                                    req_double(sv, &format!("status.{}", sk))?;
                            }
                            "text_file" | "statusTextFile" => {
                                claim("statusTextFile", &format!("status.{}", sk))?;
                                config.status_text_file =
                                    Some(req_string(sv, &format!("status.{}", sk))?);
                            }
                            "state_file" | "statusStateFile" => {
                                claim("statusStateFile", &format!("status.{}", sk))?;
                                config.status_state_file =
                                    Some(req_string(sv, &format!("status.{}", sk))?);
                            }
                            "commands" | "statusCommands" => {
                                claim("statusCommands", &format!("status.{}", sk))?;
                                config.status_commands =
                                    parse_command_list(sv, &format!("status.{}", sk))?;
                            }
                            _ => return Err(format!("unknown key 'status.{}'", sk)),
                        }
                    }
                }
                _ => return Err(format!("unknown configuration key '{}'", key)),
            }
        }
        Ok(config)
    }

    /// Updates an existing TOML document in-place via `toml_edit` so user comments stay intact,
    /// falling back to canonical `to_toml()` when starting fresh.
    pub fn to_toml_preserving_comments(&self, existing_toml: Option<&str>) -> String {
        if let Some(src) = existing_toml {
            if let Ok(mut doc) = src.parse::<DocumentMut>() {
                self.apply_to_toml_document(&mut doc);
                let out = doc.to_string();
                if Self::decode_toml(&out).as_ref() == Ok(self) {
                    return out;
                }
            }
        }
        self.to_toml()
    }

    fn apply_to_toml_document(&self, doc: &mut DocumentMut) {
        let defaults = Configuration::default();
        fn to_str_array(items: &[String]) -> Value {
            let mut arr = toml_edit::Array::new();
            for s in items {
                arr.push(s.as_str());
            }
            Value::Array(arr)
        }
        fn clean_float(val: f64) -> f64 {
            ((val * 10000.0).round()) / 10000.0
        }
        fn set_gap(layout: &mut Table, key: &str, gap: f64) {
            if gap == 0.0 && !layout.contains_key(key) {
                return;
            }
            let mut value = if gap.fract().abs() < 0.0001 {
                Value::from(gap.round() as i64)
            } else {
                Value::from(clean_float(gap))
            };
            // Keep comments on the line being edited, as well as its surrounding whitespace.
            if let Some(previous) = layout.get(key).and_then(Item::as_value) {
                *value.decor_mut() = previous.decor().clone();
            }
            layout[key] = Item::Value(value);
        }

        // Clean any legacy flat root keys before updating canonical sections
        for flat in [
            "workspace_mode",
            "workspaceMode",
            "workspace_count",
            "workspaceCount",
            "master_ratio",
            "masterRatio",
            "ratio_step",
            "ratioStep",
            "master_count",
            "masterCount",
            "outer_gap",
            "outerGap",
            "screen_padding",
            "screenPadding",
            "margin",
            "padding",
            "inner_gap",
            "innerGap",
            "window_gap",
            "windowGap",
            "gap",
            "spacing",
            "ignore_apps",
            "ignoreApps",
            "app_workspaces",
            "appWorkspaces",
            "float_windows",
            "floatWindows",
            "status_format",
            "statusFormat",
            "status_template",
            "statusTemplate",
            "status_show_icon",
            "statusShowIcon",
            "workspace_current",
            "workspaceCurrent",
            "workspace_other",
            "workspaceOther",
            "status_fonts",
            "statusFonts",
            "status_font_size",
            "statusFontSize",
            "space_labels",
            "spaceLabels",
            "workspace_icons",
            "workspaceIcons",
            "status_text_file",
            "statusTextFile",
            "status_state_file",
            "statusStateFile",
            "commands",
            "status_commands",
            "statusCommands",
        ] {
            doc.remove(flat);
        }

        doc["modifiers"] = Item::Value(to_str_array(&self.modifiers));

        let has_ws_section = self.workspace_mode != defaults.workspace_mode
            || self.workspace_count != defaults.workspace_count
            || doc.contains_key("workspaces");
        if has_ws_section {
            if !doc.contains_key("workspaces") {
                doc["workspaces"] = Item::Table(Table::new());
            }
            if let Some(ws) = doc["workspaces"].as_table_mut() {
                ws["mode"] = toml_edit::value(self.workspace_mode.as_str());
                ws["count"] = toml_edit::value(self.workspace_count as i64);
                if !self.space_labels.is_empty() {
                    ws["labels"] = Item::Value(to_str_array(&self.space_labels));
                } else {
                    ws.remove("labels");
                }
            }
        }

        if !doc.contains_key("layout") {
            doc["layout"] = Item::Table(Table::new());
        }
        if let Some(layout) = doc["layout"].as_table_mut() {
            for alias in [
                "outerGap",
                "screen_padding",
                "screenPadding",
                "margin",
                "padding",
                "innerGap",
                "window_gap",
                "windowGap",
                "gap",
                "spacing",
            ] {
                layout.remove(alias);
            }
            layout["master_ratio"] = toml_edit::value(clean_float(self.master_ratio));
            layout["ratio_step"] = toml_edit::value(clean_float(self.ratio_step));
            layout["master_count"] = toml_edit::value(self.master_count as i64);
            set_gap(layout, "outer_gap", self.outer_gap);
            set_gap(layout, "inner_gap", self.inner_gap);
        }

        if !self.ignore_apps.is_empty()
            || !self.app_workspaces.is_empty()
            || !self.float_windows.is_empty()
            || doc.contains_key("rules")
        {
            if !doc.contains_key("rules") {
                doc["rules"] = Item::Table(Table::new());
            }
            if let Some(rules) = doc["rules"].as_table_mut() {
                if !self.ignore_apps.is_empty() {
                    rules["ignore_apps"] = Item::Value(to_str_array(&self.ignore_apps));
                } else {
                    rules.remove("ignore_apps");
                }
                if !self.app_workspaces.is_empty() {
                    let mut app_ws = Table::new();
                    for (bundle, target) in &self.app_workspaces {
                        match target {
                            WorkspaceTarget::Index(n) => {
                                app_ws[bundle.as_str()] = toml_edit::value(*n as i64);
                            }
                            WorkspaceTarget::Label(s) => {
                                app_ws[bundle.as_str()] = toml_edit::value(s.as_str());
                            }
                        }
                    }
                    rules["app_workspaces"] = Item::Table(app_ws);
                } else {
                    rules.remove("app_workspaces");
                }
                if !self.float_windows.is_empty() {
                    let mut aot = toml_edit::ArrayOfTables::new();
                    for r in &self.float_windows {
                        let mut t = Table::new();
                        t["app"] = toml_edit::value(r.app.as_str());
                        if let Some(ref titles) = r.titles {
                            t["titles"] = Item::Value(to_str_array(titles));
                        }
                        if let Some(ref excepts) = r.except_titles {
                            t["except_titles"] = Item::Value(to_str_array(excepts));
                        }
                        aot.push(t);
                    }
                    rules["float_windows"] = Item::ArrayOfTables(aot);
                } else {
                    rules.remove("float_windows");
                }
            }
        }

        if !doc.contains_key("status") {
            doc["status"] = Item::Table(Table::new());
        }
        if let Some(status) = doc["status"].as_table_mut() {
            status["show_icon"] = toml_edit::value(self.status_show_icon);
            if !self.space_labels.is_empty() && !has_ws_section {
                status["space_labels"] = Item::Value(to_str_array(&self.space_labels));
            } else {
                status.remove("space_labels");
            }
            if !self.workspace_icons.is_empty() {
                status["workspace_icons"] = Item::Value(to_str_array(&self.workspace_icons));
            } else {
                status.remove("workspace_icons");
            }
            if let Some(ref tmpl) = self.status_template {
                status["template"] = toml_edit::value(tmpl.as_str());
                status.remove("format");
            } else {
                status.remove("template");
                if self.status_format != defaults.status_format {
                    status["format"] = toml_edit::value(self.status_format.as_str());
                } else {
                    status.remove("format");
                }
            }
            if self.workspace_current != defaults.workspace_current || self.status_template.is_some()
            {
                status["workspace_current"] = toml_edit::value(self.workspace_current.as_str());
            } else {
                status.remove("workspace_current");
            }
            if self.workspace_other != defaults.workspace_other || self.status_template.is_some() {
                status["workspace_other"] = toml_edit::value(self.workspace_other.as_str());
            } else {
                status.remove("workspace_other");
            }
            if !self.status_fonts.is_empty() {
                status["fonts"] = Item::Value(to_str_array(&self.status_fonts));
            } else {
                status.remove("fonts");
            }
            if (self.status_font_size - defaults.status_font_size).abs() > 0.0001 {
                status["font_size"] = toml_edit::value(clean_float(self.status_font_size));
            } else {
                status.remove("font_size");
            }
            if let Some(ref tf) = self.status_text_file {
                status["text_file"] = toml_edit::value(tf.as_str());
            } else {
                status.remove("text_file");
            }
            if let Some(ref sf) = self.status_state_file {
                status["state_file"] = toml_edit::value(sf.as_str());
            } else {
                status.remove("state_file");
            }
            if !self.status_commands.is_empty() {
                let mut aot = toml_edit::ArrayOfTables::new();
                for cmd in &self.status_commands {
                    let mut t = Table::new();
                    t["name"] = toml_edit::value(cmd.name.as_str());
                    t["executable"] = toml_edit::value(cmd.executable.as_str());
                    if let Some(ref args) = cmd.arguments {
                        t["arguments"] = Item::Value(to_str_array(args));
                    }
                    if let Some(iv) = cmd.interval {
                        t["interval"] = toml_edit::value(clean_float(iv));
                    }
                    if let Some(to) = cmd.timeout {
                        t["timeout"] = toml_edit::value(clean_float(to));
                    }
                    if let Some(mk) = cmd.markup {
                        t["markup"] = toml_edit::value(mk);
                    }
                    if let Some(oc) = cmd.on_change {
                        t["on_change"] = toml_edit::value(oc);
                    }
                    aot.push(t);
                }
                status["commands"] = Item::ArrayOfTables(aot);
            } else {
                status.remove("commands");
            }
        }
    }

    pub fn to_toml(&self) -> String {
        let mut doc = "# Talus configuration (~/.talus.toml)\n"
            .parse::<DocumentMut>()
            .unwrap_or_default();
        self.apply_to_toml_document(&mut doc);
        doc.to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn gaps_decode_validate_and_preserve_comments_on_save() {
        let old_json: Configuration = serde_json::from_str("{}").unwrap();
        assert_eq!((old_json.outer_gap, old_json.inner_gap), (0.0, 0.0));
        let source = "# My layout\n[layout]\n# Leave room around the screen\nouter_gap = 12 # screen edge\ninner_gap = 8 # between windows\n";
        let mut cfg = Configuration::decode_toml(source).unwrap();
        assert_eq!((cfg.outer_gap, cfg.inner_gap), (12.0, 8.0));
        cfg.outer_gap = 24.0;
        cfg.inner_gap = 0.0;
        let saved = cfg.to_toml_preserving_comments(Some(source));
        assert!(saved.contains("# My layout"));
        assert!(saved.contains("# Leave room around the screen"));
        assert!(saved.contains("outer_gap = 24 # screen edge"));
        assert!(saved.contains("inner_gap = 0 # between windows"));
        assert_eq!(Configuration::decode_toml(&saved).unwrap(), cfg);

        for section in ["", "[layout]\n"] {
            for alias in [
                "outer_gap",
                "outerGap",
                "screen_padding",
                "screenPadding",
                "margin",
                "padding",
            ] {
                let input = format!("{section}{alias} = 16\n");
                let parsed = Configuration::decode_toml(&input).unwrap();
                assert_eq!(parsed.outer_gap, 16.0);
                assert_eq!(
                    Configuration::decode_toml(&parsed.to_toml_preserving_comments(Some(&input)))
                        .unwrap(),
                    parsed
                );
            }
            for alias in [
                "inner_gap",
                "innerGap",
                "window_gap",
                "windowGap",
                "gap",
                "spacing",
            ] {
                let input = format!("{section}{alias} = 7.5\n");
                let parsed = Configuration::decode_toml(&input).unwrap();
                assert_eq!(parsed.inner_gap, 7.5);
                assert_eq!(
                    Configuration::decode_toml(&parsed.to_toml_preserving_comments(Some(&input)))
                        .unwrap(),
                    parsed
                );
            }
        }
        for input in [
            "outer_gap = -1",
            "inner_gap = 65",
            "outer_gap = nan",
            "inner_gap = inf",
            "outer_gap = '12'",
            "inner_gap = true",
            "outer_gap = 12\n[layout]\nmargin = 12",
            "[layout]\ninner_gap = 8\ngap = 8",
        ] {
            assert!(
                Configuration::decode_toml(input)
                    .and_then(|cfg| cfg.validate())
                    .is_err(),
                "{input}"
            );
        }
        let max = Configuration::decode_toml("[layout]\nouter_gap = 64\ninner_gap = 64").unwrap();
        max.validate().unwrap();
    }

    #[test]
    fn test_config_toml_roundtrip_and_comment_preservation() {
        let toml_with_comments = r#"# User's custom header comment
modifiers = ["option"]

[workspaces]
# Keep 6 virtual workspaces
mode = "virtual"
count = 6

[layout]
master_ratio = 0.6
ratio_step = 0.05
master_count = 2

[rules]
ignore_apps = ["com.apple.systempreferences"]

[rules.app_workspaces]
"com.apple.Safari" = 2
"com.tencent.xinWeChat" = "聊天"

[[rules.float_windows]]
app = "com.tencent.xinWeChat"
except_titles = ["微信", "微信 (*)", "WeChat", "WeChat (*)"]

[status]
show_icon = false
space_labels = ["终端", "网页", "聊天"]
workspace_icons = ["terminal", "globe", "chevron.left.forwardslash.chevron.right"]
template = "%spaces%  <fc=#89CFC2>%layout%</fc>  %clock%"
workspace_current = "<fc=#10201E,#89CFC2> %label%%fullscreen% </fc>"
workspace_other = "%label%%fullscreen%"
fonts = ["Menlo-Regular"]
font_size = 12.0

[[status.commands]]
name = "clock"
executable = "/bin/date"
arguments = ["+%H:%M"]
interval = 30.0
timeout = 2.0
markup = false
on_change = true
"#;
        let mut cfg = Configuration::decode_toml(toml_with_comments).expect("valid TOML");
        cfg.validate().expect("validates");
        assert_eq!(cfg.modifiers, vec!["option"]);
        assert_eq!(cfg.workspace_mode, "virtual");
        assert_eq!(cfg.workspace_count, 6);
        assert_eq!(
            cfg.app_workspaces.get("com.apple.Safari"),
            Some(&WorkspaceTarget::Index(2))
        );
        assert_eq!(
            cfg.app_workspaces.get("com.tencent.xinWeChat"),
            Some(&WorkspaceTarget::Label("聊天".to_string()))
        );
        assert_eq!(
            cfg.app_workspaces["com.tencent.xinWeChat"].resolve(6, &cfg.space_labels),
            Some(2)
        );

        let rule = &cfg.float_windows[0];
        assert!(!rule.matches(Some("com.tencent.xinWeChat"), "微信 (3)"));
        assert!(rule.matches(Some("com.tencent.xinWeChat"), "图片和视频"));

        // Modify master_ratio and save while preserving comments!
        cfg.master_ratio = 0.55;
        let updated = cfg.to_toml_preserving_comments(Some(toml_with_comments));
        assert!(updated.contains("# User's custom header comment"));
        assert!(updated.contains("# Keep 6 virtual workspaces"));
        let reparsed = Configuration::decode_toml(&updated).expect("reparsed");
        assert_eq!(reparsed, cfg);
    }
}
