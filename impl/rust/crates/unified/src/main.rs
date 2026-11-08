//! `unified`: the CLI of spec/CORE.md §3. Every mode prints one JSON line on stdout; a non-zero
//! exit code means failure.

mod args;
mod net;
mod offline;

use args::Args;

fn main() {
    let args = match Args::parse(std::env::args().skip(1)) {
        Ok(a) => a,
        Err(e) => {
            eprintln!(
                "unified: {e}\nusage: unified sim|synctest|replay|session|relay|client|snapshot|resume|bench --key value ..."
            );
            std::process::exit(2);
        }
    };
    let r = match args.mode.as_str() {
        "sim" => offline::sim(&args),
        "synctest" => offline::synctest(&args),
        "replay" => offline::replay(&args),
        "snapshot" => offline::snapshot(&args),
        "resume" => offline::resume(&args),
        "bench" => offline::bench(&args),
        "session" => net::session(&args),
        "relay" => net::relay(&args),
        "client" => net::client(&args),
        m => Err(format!("unknown mode {m:?}")),
    };
    match r {
        Ok((json, ok)) => {
            println!("{}", json.render());
            if !ok {
                std::process::exit(1);
            }
        }
        Err(e) => {
            eprintln!("unified {}: {e}", args.mode);
            println!("{}", simcore::json::Json::obj().with("mode", args.mode.as_str()).with("error", e).render());
            std::process::exit(1);
        }
    }
}
