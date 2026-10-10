//! JSON inspection with heterogeneous structure, array exceptions and pointers.
use crate::compress::{
    recovery,
    tee::{self, TruncateRequest, truncate_with_tee},
};
use clap::Args;
use serde_json::Value;
use std::{
    collections::{BTreeMap, BTreeSet},
    io::Read,
    path::PathBuf,
};

#[derive(Args, Debug)]
pub struct JsonArgs {
    pub path: Option<PathBuf>,
    /// Show all distinct array shapes, without scalar values.
    #[arg(short, long)]
    pub structure: bool,
    /// Select a value using an RFC 6901 JSON pointer, e.g. /records/250.
    #[arg(long)]
    pub pointer: Option<String>,
    /// Filter an array by POINTER=JSON, e.g. '/status="failed"'.
    #[arg(long = "where")]
    pub predicate: Option<String>,
    /// Print the selected JSON without summarization or byte limits.
    #[arg(long, conflicts_with = "structure")]
    pub full: bool,
}

pub fn run(args: JsonArgs) -> anyhow::Result<()> {
    let raw = if let Some(path) = &args.path {
        String::from_utf8(recovery::read(path)?)?
    } else {
        let mut s = String::new();
        std::io::stdin().read_to_string(&mut s)?;
        s
    };
    let document: Value = serde_json::from_str(&raw)?;
    let selected = if let Some(pointer) = &args.pointer {
        document
            .pointer(pointer)
            .ok_or_else(|| anyhow::anyhow!("JSON pointer not found: {pointer}"))?
    } else {
        &document
    };
    let filtered;
    let selected = if let Some(predicate) = &args.predicate {
        let (pointer, expected) = predicate
            .split_once('=')
            .ok_or_else(|| anyhow::anyhow!("--where requires POINTER=JSON"))?;
        let expected: Value = serde_json::from_str(expected)?;
        let items = selected.as_array().ok_or_else(|| {
            anyhow::anyhow!("--where requires an array (select one with --pointer)")
        })?;
        filtered = Value::Array(
            items
                .iter()
                .filter(|v| v.pointer(pointer) == Some(&expected))
                .cloned()
                .collect(),
        );
        &filtered
    } else {
        selected
    };
    let pretty = serde_json::to_string_pretty(selected)? + "\n";
    if args.full {
        print!("{pretty}");
        return Ok(());
    }
    let mut rendered = String::new();
    if args.structure {
        render_structure(selected, 0, &mut rendered);
    } else if pretty.len() > tee::output_budget() {
        render_compact(selected, 0, &mut rendered);
    } else {
        rendered = pretty.clone();
    }
    let explicit = args.structure || args.pointer.is_some() || args.predicate.is_some();
    if args.structure {
        // A requested structure view may be larger than a tiny input. Honor it
        // while retaining exact input, including stdin, for later inspection.
        match tee::resolve_tee_dir(None)
            .and_then(|d| recovery::store(raw.as_bytes(), &d, recovery::Limits::from_env()))
        {
            Ok(path) => rendered.push_str(&format!("[full output: {}]\n", path.display())),
            Err(_) => {
                print!("{raw}");
                return Ok(());
            }
        }
    }
    let original = if explicit { &pretty } else { &raw };
    // Explicit projections have intentionally selected a different payload.
    let guarded = truncate_with_tee(TruncateRequest {
        content: &rendered,
        original: if args.structure { None } else { Some(original) },
        head_lines: 2,
        tail_lines: 1,
        tee_dir: None,
        max_bytes: None,
    })?;
    print!("{}", guarded.content);
    Ok(())
}

fn shape(v: &Value) -> String {
    match v {
        Value::Null => "null".into(),
        Value::Bool(_) => "bool".into(),
        Value::Number(_) => "number".into(),
        Value::String(_) => "string".into(),
        Value::Array(a) => {
            let shapes: BTreeSet<_> = a.iter().map(shape).collect();
            format!(
                "array<{}>",
                shapes.into_iter().collect::<Vec<_>>().join("|")
            )
        }
        Value::Object(m) => {
            let fields: BTreeMap<_, _> = m.iter().map(|(k, v)| (k, shape(v))).collect();
            format!("{fields:?}")
        }
    }
}

fn render_structure(v: &Value, depth: usize, out: &mut String) {
    let indent = "  ".repeat(depth);
    match v {
        Value::Array(items) => {
            out.push_str(&format!("{indent}[{}] array\n", items.len()));
            let mut shapes = BTreeSet::new();
            for (i, item) in items.iter().enumerate() {
                if shapes.insert(shape(item)) {
                    out.push_str(&format!("{indent}  [{i}] shape:\n"));
                    render_structure(item, depth + 2, out);
                }
            }
        }
        Value::Object(map) => {
            for (key, child) in map {
                out.push_str(&format!("{indent}{key}:\n"));
                render_structure(child, depth + 1, out);
            }
        }
        _ => out.push_str(&format!("{indent}<{}>\n", shape(v))),
    }
}

fn interesting_indices(items: &[Value]) -> BTreeSet<usize> {
    let mut keep: BTreeSet<_> = (0..items.len().min(3))
        .chain(items.len().saturating_sub(2)..items.len())
        .collect();
    let mut shapes: BTreeMap<String, Vec<usize>> = BTreeMap::new();
    let mut fields: BTreeMap<String, BTreeMap<String, Vec<usize>>> = BTreeMap::new();
    for (i, v) in items.iter().enumerate() {
        shapes.entry(shape(v)).or_default().push(i);
        if let Value::Object(map) = v {
            for (key, value) in map {
                if value.is_string() || value.is_boolean() || value.is_null() {
                    fields
                        .entry(key.clone())
                        .or_default()
                        .entry(value.to_string())
                        .or_default()
                        .push(i);
                }
            }
        }
    }
    for indices in shapes.values() {
        keep.insert(indices[0]);
        if indices.len() <= 3 {
            keep.extend(indices);
        }
    }
    for values in fields.values() {
        // Low-cardinality categorical fields expose uncommon states without
        // treating unique IDs or free-text messages as anomalies.
        if values.len() <= 12 && values.len() * 4 <= items.len() {
            for indices in values.values() {
                keep.insert(indices[0]);
                if indices.len() <= 3 {
                    keep.extend(indices);
                }
            }
        }
    }
    keep
}

fn render_compact(v: &Value, depth: usize, out: &mut String) {
    let indent = "  ".repeat(depth);
    match v {
        Value::Array(items) if items.len() > 12 => {
            let keep = interesting_indices(items);
            out.push_str(&format!("{indent}[{} items; {} omitted; sampled endpoints, shapes and uncommon categorical values]\n", items.len(), items.len() - keep.len()));
            for i in keep {
                out.push_str(&format!("{indent}[{i}] {}\n", items[i]));
            }
        }
        Value::Object(map) => {
            for (key, child) in map {
                out.push_str(&format!("{indent}{key}: "));
                if child.is_array() || child.is_object() {
                    out.push('\n');
                    render_compact(child, depth + 1, out);
                } else {
                    out.push_str(&format!("{child}\n"));
                }
            }
        }
        _ => out.push_str(&format!("{indent}{v}\n")),
    }
}
