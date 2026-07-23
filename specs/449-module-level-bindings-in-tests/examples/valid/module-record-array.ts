// A module-level `const` holding a record, an array, and a nested value is
// readable from a test block.
type Cfg = { host: string, port: int };

const cfg: Cfg = { host: "localhost", port: 8080 };
const nums: int[] = [1, 2, 3];
const names: string[] = ["alpha", "beta"];

test("record and array module state", () => {
  expect(cfg.host == "localhost");
  expect(cfg.port == 8080);
  expect(nums.length == 3);
  expect(nums[2] == 3);
  expect(names[1] == "beta");
});
