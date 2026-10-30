//! Writes JSON the way Swift's `JSONEncoder` does with
//! `[.prettyPrinted, .sortedKeys]`: two-space indent, `"key" : value`, keys
//! sorted, `/` escaped as `\/`. Matching it byte for byte keeps the
//! "only back up when the bytes changed" rule in `persistence` honest.

use serde::Serialize;
use serde_json::Value;

pub fn to_string<T: Serialize>(value: &T) -> serde_json::Result<String> {
    let value = serde_json::to_value(value)?;
    let mut out = String::new();
    write_value(&value, 0, &mut out);
    Ok(out)
}

fn write_value(value: &Value, depth: usize, out: &mut String) {
    match value {
        Value::Null => out.push_str("null"),
        Value::Bool(b) => out.push_str(if *b { "true" } else { "false" }),
        Value::Number(n) => out.push_str(&n.to_string()),
        Value::String(s) => write_string(s, out),
        Value::Array(items) => {
            if items.is_empty() {
                out.push_str("[]");
                return;
            }
            out.push_str("[\n");
            for (i, item) in items.iter().enumerate() {
                indent(depth + 1, out);
                write_value(item, depth + 1, out);
                if i + 1 < items.len() {
                    out.push(',');
                }
                out.push('\n');
            }
            indent(depth, out);
            out.push(']');
        }
        Value::Object(map) => {
            if map.is_empty() {
                out.push_str("{}");
                return;
            }
            // serde_json's map is a BTreeMap, so iteration is already sorted.
            out.push_str("{\n");
            for (i, (key, item)) in map.iter().enumerate() {
                indent(depth + 1, out);
                write_string(key, out);
                out.push_str(" : ");
                write_value(item, depth + 1, out);
                if i + 1 < map.len() {
                    out.push(',');
                }
                out.push('\n');
            }
            indent(depth, out);
            out.push('}');
        }
    }
}

fn indent(depth: usize, out: &mut String) {
    for _ in 0..depth {
        out.push_str("  ");
    }
}

fn write_string(s: &str, out: &mut String) {
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '/' => out.push_str("\\/"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            '\u{08}' => out.push_str("\\b"),
            '\u{0C}' => out.push_str("\\f"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn matches_swift_pretty_sorted_output() {
        let value = json!({"tabs": [], "name": "a/b", "isCollapsed": false, "nested": {"z": 1, "a": "x\n"}});
        let expected = "{\n  \"isCollapsed\" : false,\n  \"name\" : \"a\\/b\",\n  \"nested\" : {\n    \"a\" : \"x\\n\",\n    \"z\" : 1\n  },\n  \"tabs\" : []\n}";
        assert_eq!(to_string(&value).unwrap(), expected);
    }

    #[test]
    fn arrays_of_objects_indent() {
        let value = json!({"groups": [{"id": "A"}]});
        assert_eq!(
            to_string(&value).unwrap(),
            "{\n  \"groups\" : [\n    {\n      \"id\" : \"A\"\n    }\n  ]\n}"
        );
    }
}
