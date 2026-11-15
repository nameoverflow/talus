use crate::config::{ expand_tilde, Configuration };
use crate::virtual_workspaces::write_atomic_0600;
use serde::{Deserialize, Serialize};
use std::path::Path;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SpaceEntry {
    pub id: u64,
    pub is_current: bool,
    pub is_fullscreen: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub window_count: Option<usize>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StatusValues {
    pub spaces: Option<Vec<SpaceEntry>>,
    pub layout: String,
    pub title: String,
    pub count: usize,
    pub custom: String,
    pub paused: bool,
    #[serde(default)]
    pub space_labels: Vec<String>,
    #[serde(default)]
    pub space_icons: Vec<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum StatusBoxType {
    Full,
    Bottom,
    Top,
    HBoth,
    VBoth,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StatusBoxStyle {
    #[serde(rename = "type")]
    pub box_type: StatusBoxType,
    pub width: f64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub color: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub radius: Option<f64>,
}

impl Default for StatusBoxStyle {
    fn default() -> Self {
        Self {
            box_type: StatusBoxType::Full,
            width: 2.0,
            color: None,
            radius: None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StatusSegmentStyle {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub foreground: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub background: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub font: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub font_size: Option<f64>,
    #[serde(default)]
    pub dimmed: bool,
    #[serde(rename = "box", skip_serializing_if = "Option::is_none")]
    pub box_style: Option<StatusBoxStyle>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StatusPart {
    pub text: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub style: Option<StatusSegmentStyle>,
    pub is_current: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub workspace_index: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub symbol_name: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct StatusExport {
    pub spaces: Option<Vec<SpaceEntry>>,
    pub layout: String,
    pub title: String,
    pub count: usize,
    pub paused: bool,
}

pub fn write_status(data: &[u8], destination: &Path) -> Result<(), String> {
    write_atomic_0600(data, destination)
}

pub fn read_custom_status(path: &str) -> String {
    let expanded = expand_tilde(path, None);
    let p = Path::new(&expanded);
    let Ok(meta) = std::fs::symlink_metadata(p) else {
        return String::new();
    };
    if !meta.file_type().is_file() || meta.len() > 1_048_576 {
        return String::new();
    }
    use std::io::Read;
    let Ok(mut file) = std::fs::File::open(p) else {
        return String::new();
    };
    let mut buf = vec![0u8; 4096];
    let Ok(n) = file.read(&mut buf) else {
        return String::new();
    };
    buf.truncate(n);
    String::from_utf8(buf).unwrap_or_default()
}

fn clean_whitespace(text: &str, limit_chars: usize) -> String {
    let mut out = String::new();
    let mut in_ws = false;
    for ch in text.chars() {
        if ch == '\r' || ch == '\n' || ch == '\t' {
            if !in_ws {
                out.push(' ');
                in_ws = true;
            }
        } else {
            in_ws = false;
            out.push(ch);
        }
    }
    out.chars().take(limit_chars).collect()
}

pub fn render_status(format: &str, values: &StatusValues) -> String {
    let spaces = match &values.spaces {
        Some(entries) => entries
            .iter()
            .enumerate()
            .map(|(index, item)| {
                let label = values
                    .space_labels
                    .get(index)
                    .cloned()
                    .unwrap_or_else(|| (index + 1).to_string());
                let number = format!("{}{}", label, if item.is_fullscreen { "•" } else { "" });
                if item.is_current {
                    format!("[{}]", number)
                } else {
                    number
                }
            })
            .collect::<Vec<_>>()
            .join(" "),
        None => "?".to_string(),
    };

    let layout_str = if values.paused {
        "Paused"
    } else {
        values.layout.as_str()
    };
    let title_clean = clean_whitespace(&values.title, 24);
    let count_str = values.count.to_string();
    let custom_clean = clean_whitespace(&values.custom, 48);

    let mut result = String::new();
    let mut rest = format;
    while let Some(open) = rest.find('{') {
        result.push_str(&rest[..open]);
        let after_open = &rest[open..];
        let matched = [
            ("{spaces}", spaces.as_str()),
            ("{layout}", layout_str),
            ("{title}", title_clean.as_str()),
            ("{count}", count_str.as_str()),
            ("{custom}", custom_clean.as_str()),
        ]
        .into_iter()
        .find(|(tok, _)| after_open.starts_with(tok));

        if let Some((tok, rep)) = matched {
            result.push_str(rep);
            rest = &after_open[tok.len()..];
        } else {
            result.push('{');
            rest = &after_open[1..];
        }
    }
    result.push_str(rest);
    clean_whitespace(&result, 160)
}

fn markup_color(value: &str) -> Option<String> {
    match value.to_lowercase().as_str() {
        "black" => return Some("#000000".to_string()),
        "white" => return Some("#FFFFFF".to_string()),
        "red" => return Some("#FF5555".to_string()),
        "green" => return Some("#50FA7B".to_string()),
        "blue" => return Some("#6272A4".to_string()),
        "yellow" => return Some("#F1FA8C".to_string()),
        "cyan" => return Some("#8BE9FD".to_string()),
        "magenta" => return Some("#FF79C6".to_string()),
        _ => {}
    }
    if let Some(hex) = value.strip_prefix('#') {
        if (hex.len() == 6 || hex.len() == 8) && hex.chars().all(|c| c.is_ascii_hexdigit()) {
            return Some(value.to_string());
        }
    }
    None
}

fn is_valid_sf_symbol(sym: &str) -> bool {
    !sym.is_empty()
        && sym.len() <= 64
        && sym
            .chars()
            .next()
            .map(|c| c.is_ascii_alphanumeric())
            .unwrap_or(false)
        && sym
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '.' || c == '_' || c == '-')
}

fn parse_box_tag(tag: &str) -> Option<StatusBoxStyle> {
    let body = tag.get(3..)?.trim();
    let mut box_style = StatusBoxStyle::default();
    if body.is_empty() {
        return Some(box_style);
    }
    for token in body.split_whitespace() {
        let (k, v) = token.split_once('=')?;
        match k.to_lowercase().as_str() {
            "type" => {
                box_style.box_type = match v.to_lowercase().as_str() {
                    "full" => StatusBoxType::Full,
                    "bottom" => StatusBoxType::Bottom,
                    "top" => StatusBoxType::Top,
                    "hboth" => StatusBoxType::HBoth,
                    "vboth" => StatusBoxType::VBoth,
                    _ => return None,
                };
            }
            "width" => {
                let w: f64 = v.parse().ok()?;
                if !(1.0..=4.0).contains(&w) {
                    return None;
                }
                box_style.width = w;
            }
            "color" => {
                box_style.color = Some(markup_color(v)?);
            }
            "radius" => {
                let r: f64 = v.parse().ok()?;
                if !(0.0..=9.0).contains(&r) {
                    return None;
                }
                box_style.radius = Some(r);
            }
            _ => return None,
        }
    }
    Some(box_style)
}

pub fn parse_status_markup<F>(
    source: &str,
    fonts: &[String],
    font_size: f64,
    initial: Option<StatusSegmentStyle>,
    current: bool,
    workspace_index: Option<usize>,
    resolve: F,
) -> Vec<StatusPart>
where
    F: Fn(&str, &StatusSegmentStyle) -> Option<Vec<StatusPart>>,
{
    let chars: Vec<char> = source.chars().take(4096).collect();
    let mut result: Vec<StatusPart> = Vec::new();
    let mut buffer = String::new();
    let mut style = initial.unwrap_or_default();
    if style.font_size.is_none() {
        style.font_size = Some(font_size);
    }
    let mut stack: Vec<(&'static str, StatusSegmentStyle)> = Vec::new();
    let mut i = 0usize;

    let flush = |buffer: &mut String,
                 result: &mut Vec<StatusPart>,
                 style: &StatusSegmentStyle| {
        if buffer.is_empty() || result.len() >= 512 {
            buffer.clear();
            return;
        }
        let clean = clean_whitespace(buffer, 512);
        if !clean.is_empty() {
            result.push(StatusPart {
                text: clean,
                style: Some(style.clone()),
                is_current: current,
                workspace_index,
                symbol_name: None,
            });
        }
        buffer.clear();
    };

    while i < chars.len() {
        let tail: String = chars[i..].iter().collect();
        if tail.starts_with("</fc>") || tail.starts_with("</fn>") || tail.starts_with("</box>") {
            let tag = if tail.starts_with("</fc>") {
                "fc"
            } else if tail.starts_with("</fn>") {
                "fn"
            } else {
                "box"
            };
            let close_len = tag.len() + 3;
            if stack.last().map(|(t, _)| *t) == Some(tag) {
                flush(&mut buffer, &mut result, &style);
                style = stack.pop().unwrap().1;
                i += close_len;
                continue;
            }
        }

        if chars[i] == '<' && stack.len() < 16 {
            if let Some(end_offset) = chars[i..].iter().position(|&c| c == '>') {
                if end_offset <= 100 {
                    let tag: String = chars[(i + 1)..(i + end_offset)].iter().collect();
                    if let Some(fc_body) = tag.strip_prefix("fc=") {
                        let pieces: Vec<&str> = fc_body.split(',').collect();
                        let fg_valid = (pieces.len() == 2 && pieces[0].is_empty())
                            || markup_color(pieces[0]).is_some();
                        if (1..=2).contains(&pieces.len())
                            && fg_valid
                            && (pieces.len() == 1 || markup_color(pieces[1]).is_some())
                        {
                            flush(&mut buffer, &mut result, &style);
                            stack.push(("fc", style.clone()));
                            if let Some(fg) = markup_color(pieces[0]) {
                                style.foreground = Some(fg);
                            }
                            if pieces.len() == 2 {
                                style.background = markup_color(pieces[1]);
                            }
                            i += end_offset + 1;
                            continue;
                        }
                    } else if let Some(fn_body) = tag.strip_prefix("fn=") {
                        if let Ok(font_idx) = fn_body.parse::<usize>() {
                            flush(&mut buffer, &mut result, &style);
                            stack.push(("fn", style.clone()));
                            style.font = fonts.get(font_idx).cloned();
                            i += end_offset + 1;
                            continue;
                        }
                    } else if tag == "box" || tag.starts_with("box ") {
                        if let Some(box_style) = parse_box_tag(&tag) {
                            flush(&mut buffer, &mut result, &style);
                            stack.push(("box", style.clone()));
                            style.box_style = Some(box_style);
                            i += end_offset + 1;
                            continue;
                        }
                    } else if let Some(sym) = tag.strip_prefix("sf=") {
                        if is_valid_sf_symbol(sym) {
                            flush(&mut buffer, &mut result, &style);
                            if result.len() < 512 {
                                result.push(StatusPart {
                                    text: String::new(),
                                    style: Some(style.clone()),
                                    is_current: current,
                                    workspace_index,
                                    symbol_name: Some(sym.to_string()),
                                });
                            }
                            i += end_offset + 1;
                            continue;
                        }
                    }
                }
            }
        }

        if chars[i] == '%' {
            let next = i + 1;
            if next < chars.len() && chars[next] == '%' {
                buffer.push('%');
                i = next + 1;
                continue;
            }
            if next < chars.len() {
                if let Some(end_rel) = chars[next..].iter().position(|&c| c == '%') {
                    if end_rel <= 32 {
                        let token: String = chars[next..(next + end_rel)].iter().collect();
                        if let Some(sub) = resolve(&token, &style) {
                            flush(&mut buffer, &mut result, &style);
                            let cap = 512usize.saturating_sub(result.len());
                            result.extend(sub.into_iter().take(cap));
                            i = next + end_rel + 1;
                            continue;
                        }
                    }
                }
            }
        }

        buffer.push(chars[i]);
        i += 1;
    }

    flush(&mut buffer, &mut result, &style);
    result
}

pub fn template_status_parts<F>(
    config: &Configuration,
    values: &StatusValues,
    command_output: F,
) -> Vec<StatusPart>
where
    F: Fn(usize) -> String,
{
    let layout_val = if values.paused {
        "Paused".to_string()
    } else {
        values.layout.clone()
    };
    let title_val: String = values.title.chars().take(24).collect();
    let count_val = values.count.to_string();
    let custom_val: String = values.custom.chars().take(48).collect();

    let literal = |text: &str,
                   style: &StatusSegmentStyle,
                   current: bool,
                   workspace_index: Option<usize>|
     -> Vec<StatusPart> {
        let clean = clean_whitespace(text, 160);
        if clean.is_empty() {
            Vec::new()
        } else {
            vec![StatusPart {
                text: clean,
                style: Some(style.clone()),
                is_current: current,
                workspace_index,
                symbol_name: None,
            }]
        }
    };

    let workspaces = |inherited: &StatusSegmentStyle| -> Vec<StatusPart> {
        let Some(ref entries) = values.spaces else {
            return literal("?", inherited, false, None);
        };
        let mut output = Vec::new();
        for (index, entry) in entries.iter().enumerate() {
            if index > 0 {
                output.extend(literal(" ", inherited, false, None));
            }
            let label = values
                .space_labels
                .get(index)
                .cloned()
                .unwrap_or_else(|| (index + 1).to_string());
            let is_occupied = entry.window_count.unwrap_or(0) > 0;
            let idx_str = (index + 1).to_string();
            let fs_str = if entry.is_fullscreen { "•" } else { "" };
            let occ_str = if !entry.is_current && is_occupied {
                "•"
            } else {
                ""
            };
            let ws_template = if entry.is_current {
                &config.workspace_current
            } else {
                &config.workspace_other
            };
            let mut entry_style = inherited.clone();
            if !entry.is_current && entry.window_count == Some(0) {
                entry_style.dimmed = true;
            }
            let sub_parts = parse_status_markup(
                ws_template,
                &config.status_fonts,
                config.status_font_size,
                Some(entry_style),
                entry.is_current,
                Some(index),
                |token, style| match token {
                    "icon" => {
                        let icon_spec = values
                            .space_icons
                            .get(index)
                            .map(|s| s.as_str())
                            .unwrap_or("");
                        if is_valid_sf_symbol(icon_spec) {
                            Some(vec![StatusPart {
                                text: String::new(),
                                style: Some(style.clone()),
                                is_current: entry.is_current,
                                workspace_index: Some(index),
                                symbol_name: Some(icon_spec.to_string()),
                            }])
                        } else {
                            let fallback = if icon_spec.is_empty() {
                                label.as_str()
                            } else {
                                icon_spec
                            };
                            Some(literal(fallback, style, entry.is_current, Some(index)))
                        }
                    }
                    "label" => Some(literal(&label, style, entry.is_current, Some(index))),
                    "index" => Some(literal(&idx_str, style, entry.is_current, Some(index))),
                    "fullscreen" => Some(literal(fs_str, style, entry.is_current, Some(index))),
                    "occupied" => Some(literal(occ_str, style, entry.is_current, Some(index))),
                    _ => None,
                },
            );
            output.extend(sub_parts);
        }
        output
    };

    let legacy = config
        .status_format
        .replace("{spaces}", "%spaces%")
        .replace("{layout}", "%layout%")
        .replace("{title}", "%title%")
        .replace("{count}", "%count%")
        .replace("{custom}", "%custom%");
    let template_str = config.status_template.as_deref().unwrap_or(&legacy);

    let raw = parse_status_markup(
        template_str,
        &config.status_fonts,
        config.status_font_size,
        None,
        false,
        None,
        |token, style| {
            if token == "spaces" {
                return Some(workspaces(style));
            }
            match token {
                "layout" => return Some(literal(&layout_val, style, false, None)),
                "title" => return Some(literal(&title_val, style, false, None)),
                "count" => return Some(literal(&count_val, style, false, None)),
                "custom" => return Some(literal(&custom_val, style, false, None)),
                _ => {}
            }
            if let Some(index) = config.status_commands.iter().position(|c| c.name == token) {
                let text = command_output(index);
                if config.status_commands[index].markup == Some(true) {
                    return Some(parse_status_markup(
                        &text,
                        &config.status_fonts,
                        config.status_font_size,
                        Some(style.clone()),
                        false,
                        None,
                        |_, _| None,
                    ));
                }
                return Some(literal(&text, style, false, None));
            }
            None
        },
    );

    let mut merged: Vec<StatusPart> = Vec::new();
    for part in raw {
        if let Some(last) = merged.last_mut() {
            if last.symbol_name.is_none()
                && part.symbol_name.is_none()
                && last.style == part.style
                && last.is_current == part.is_current
                && last.workspace_index == part.workspace_index
            {
                last.text.push_str(&part.text);
                continue;
            }
        }
        merged.push(part);
    }
    merged
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_markup_and_template_rendering() {
        let mut config = Configuration::default();
        config.space_labels = vec!["term".to_string(), "web".to_string()];
        config.status_template =
            Some("%spaces% | <fc=#ABCDEF><fn=0>%layout%</fn></fc>".to_string());
        config.workspace_current = "<fc=#001122,#88CCBB> %label%%fullscreen% </fc>".to_string();
        config.workspace_other = "%index%:%label%".to_string();
        config.status_fonts = vec!["Menlo-Regular".to_string()];

        let spaces = vec![
            SpaceEntry {
                id: 1,
                is_current: false,
                is_fullscreen: false,
                window_count: Some(1),
            },
            SpaceEntry {
                id: 2,
                is_current: true,
                is_fullscreen: true,
                window_count: Some(1),
            },
        ];
        let values = StatusValues {
            spaces: Some(spaces),
            layout: "Tall".to_string(),
            title: "Editor".to_string(),
            count: 2,
            custom: "CPU".to_string(),
            paused: false,
            space_labels: config.space_labels.clone(),
            space_icons: Vec::new(),
        };
        let parts = template_status_parts(&config, &values, |_| String::new());
        let joined: String = parts.iter().map(|p| p.text.as_str()).collect();
        assert_eq!(joined, "1:term  web•  | Tall");
    }
}
