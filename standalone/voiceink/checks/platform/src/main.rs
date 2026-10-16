// Type-check the actual platform adapter without requiring a foreign WebView SDK/linker.
#[path = "../../../src-tauri/src/platform.rs"]
#[allow(dead_code, unused_imports)]
mod platform;
fn main() {}
