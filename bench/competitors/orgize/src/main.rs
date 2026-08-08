// orgize side of the bench protocol (see bench/README.md):
//   orgize-runner <file.org> <warmup> <min-time-seconds>
// prints one ns-per-iteration line per measured parse; the orchestrator does the stats.

use std::hint::black_box;
use std::time::Instant;

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 4 {
        eprintln!("usage: orgize-runner <file.org> <warmup> <min-time-seconds>");
        std::process::exit(1);
    }
    let src = std::fs::read_to_string(&args[1]).expect("read file");
    let warmup: usize = args[2].parse().expect("warmup must be an integer");
    let min_time: f64 = args[3].parse().expect("min-time must be a number");

    for _ in 0..warmup {
        black_box(orgize::Org::parse(&src));
    }

    let t = Instant::now();
    black_box(orgize::Org::parse(&src));
    let est = t.elapsed().as_secs_f64();
    let iters = ((min_time / est.max(1e-9)) as usize).clamp(5, 20_000);

    for _ in 0..iters {
        let t = Instant::now();
        black_box(orgize::Org::parse(&src));
        println!("{}", t.elapsed().as_nanos());
    }
}
