// SHA-1 and base64 against values from other implementations, not from this
// one. The RFC 6455 handshake token is the last line, because that exact
// string is what a browser compares and closes the connection over.
function main(): void {
  console.log(crypto.sha1("abc"));
  console.log(crypto.sha1(""));
  console.log(`${crypto.sha1Bytes("abc").length}`);
  console.log(crypto.base64Encode("pk:sk"));
  console.log(crypto.base64Encode("a"));
  console.log(crypto.base64Decode("aGVsbG8gd29ybGQ="));
  let key = "dGhlIHNhbXBsZSBub25jZQ==";
  console.log(crypto.base64Encode(crypto.sha1Bytes(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")));
}
main();
