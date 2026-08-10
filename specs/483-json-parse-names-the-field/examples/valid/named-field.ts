type Ask = { siteKey: string, secret: string, enabled: bool, tries: int };

function why(text: string): string {
  try {
    let a = JSON.parse<Ask>(text);
    return "parsed " + a.siteKey;
  } catch (e) {
    return e.message;
  }
}

function main(): void {
  console.log(why("{\"siteKey\":\"k\",\"enabled\":true,\"tries\":1}"));
  console.log(why("{\"siteKey\":\"k\",\"secret\":\"s\",\"enabled\":true,\"tries\":1,\"typo\":2}"));
  console.log(why("{\"siteKey\":\"k\",\"secret\":\"s\",\"enabled\":\"yes\",\"tries\":1}"));
  console.log(why("{\"siteKey\":\"k\",\"secret\":\"s\",\"enabled\":true,\"tries\":1}"));
  console.log(why("not json at all"));
}
main();
