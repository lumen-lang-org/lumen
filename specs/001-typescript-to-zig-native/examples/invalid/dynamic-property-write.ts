// Index-notation writes (user["name"] = ...) moved off E_DYNAMIC_PROPERTY_WRITE
// onto a dedicated, deliberately code-less message (spec 342). Dot-notation
// field writes still use the bare, bracketed E_DYNAMIC_PROPERTY_WRITE code --
// this fixture exercises that one.
type User = { id: int, name: string };
let user: User = { id: 1, name: "" };
user.name = "Ada";
