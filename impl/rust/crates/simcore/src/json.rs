//! A tiny JSON object writer (no serde: keeps the dependency tree to bytemuck + xxhash).

use std::fmt::Write as _;

#[derive(Clone, Debug)]
pub enum Json {
    Null,
    Bool(bool),
    Int(i64),
    Num(f64),
    Str(String),
    Arr(Vec<Json>),
    Obj(Vec<(String, Json)>),
}

impl Json {
    pub fn obj() -> Json {
        Json::Obj(Vec::new())
    }

    /// Builder: append a field to an object.
    pub fn with(mut self, key: &str, v: impl Into<Json>) -> Json {
        if let Json::Obj(fields) = &mut self {
            fields.push((key.to_string(), v.into()));
        }
        self
    }

    pub fn get(&self, key: &str) -> Option<&Json> {
        match self {
            Json::Obj(f) => f.iter().find(|(k, _)| k == key).map(|(_, v)| v),
            _ => None,
        }
    }

    pub fn render(&self) -> String {
        let mut s = String::new();
        self.write(&mut s);
        s
    }

    fn write(&self, s: &mut String) {
        match self {
            Json::Null => s.push_str("null"),
            Json::Bool(b) => s.push_str(if *b { "true" } else { "false" }),
            Json::Int(i) => {
                let _ = write!(s, "{i}");
            }
            Json::Num(x) if x.is_finite() => {
                let _ = write!(s, "{x:.3}");
            }
            Json::Num(_) => s.push_str("null"),
            Json::Str(t) => {
                s.push('"');
                for c in t.chars() {
                    match c {
                        '"' => s.push_str("\\\""),
                        '\\' => s.push_str("\\\\"),
                        '\n' => s.push_str("\\n"),
                        c if (c as u32) < 0x20 => {
                            let _ = write!(s, "\\u{:04x}", c as u32);
                        }
                        c => s.push(c),
                    }
                }
                s.push('"');
            }
            Json::Arr(a) => {
                s.push('[');
                for (i, v) in a.iter().enumerate() {
                    if i > 0 {
                        s.push(',');
                    }
                    v.write(s);
                }
                s.push(']');
            }
            Json::Obj(f) => {
                s.push('{');
                for (i, (k, v)) in f.iter().enumerate() {
                    if i > 0 {
                        s.push(',');
                    }
                    Json::Str(k.clone()).write(s);
                    s.push(':');
                    v.write(s);
                }
                s.push('}');
            }
        }
    }
}

macro_rules! from_int {
    ($($t:ty),*) => {$(impl From<$t> for Json { fn from(v: $t) -> Json { Json::Int(v as i64) } })*};
}
from_int!(u8, u16, u32, u64, usize, i32, i64);

impl From<f64> for Json {
    fn from(v: f64) -> Json {
        Json::Num(v)
    }
}
impl From<bool> for Json {
    fn from(v: bool) -> Json {
        Json::Bool(v)
    }
}
impl From<&str> for Json {
    fn from(v: &str) -> Json {
        Json::Str(v.to_string())
    }
}
impl From<String> for Json {
    fn from(v: String) -> Json {
        Json::Str(v)
    }
}
impl From<Vec<Json>> for Json {
    fn from(v: Vec<Json>) -> Json {
        Json::Arr(v)
    }
}
