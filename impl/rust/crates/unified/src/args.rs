//! Minimal `--key value` argument parsing (no clap: keeps the build small).

use std::collections::HashMap;
use std::str::FromStr;

pub struct Args {
    pub mode: String,
    kv: HashMap<String, String>,
}

impl Args {
    pub fn parse(mut it: impl Iterator<Item = String>) -> Result<Args, String> {
        let mode = it.next().ok_or("missing mode")?;
        let mut kv = HashMap::new();
        while let Some(k) = it.next() {
            let key = k.strip_prefix("--").ok_or_else(|| format!("unexpected argument {k:?}"))?;
            let v = it.next().ok_or_else(|| format!("--{key} needs a value"))?;
            kv.insert(key.to_string(), v);
        }
        Ok(Args { mode, kv })
    }

    pub fn opt<T: FromStr>(&self, key: &str) -> Result<Option<T>, String> {
        match self.kv.get(key) {
            None => Ok(None),
            Some(v) => v.parse().map(Some).map_err(|_| format!("--{key}: bad value {v:?}")),
        }
    }

    pub fn get<T: FromStr>(&self, key: &str, default: T) -> Result<T, String> {
        Ok(self.opt(key)?.unwrap_or(default))
    }

    pub fn req<T: FromStr>(&self, key: &str) -> Result<T, String> {
        self.opt(key)?.ok_or_else(|| format!("--{key} is required"))
    }

    pub fn str(&self, key: &str) -> Option<&str> {
        self.kv.get(key).map(String::as_str)
    }
}
