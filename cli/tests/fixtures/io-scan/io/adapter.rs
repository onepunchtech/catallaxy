pub fn anything_here_is_exempt() {
    let _ = std::process::Command::new("true");
    let _ = std::env::var("HOME");
}
