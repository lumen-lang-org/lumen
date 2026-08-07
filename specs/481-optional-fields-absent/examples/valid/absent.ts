// A document written before a field existed still parses.
type Node = {
  id: string,
  name: string,
  // Added after rows were already stored. The mark is what promises the old
  // ones keep working.
  source?: string,
  cases?: string,
};

function main(): void {
  // Neither optional field is present — this is the shape of every document
  // stored before they were added.
  let old = JSON.parse<Node>("{\"id\":\"a\",\"name\":\"first\"}");
  console.log(old.id + " " + old.name + " " + (old.source ?? "-") + " " + (old.cases ?? "-"));

  // One of the two, which is what a document written between the two changes
  // looks like.
  let half = JSON.parse<Node>("{\"id\":\"b\",\"name\":\"second\",\"source\":\"x\"}");
  console.log(half.id + " " + (half.source ?? "-") + " " + (half.cases ?? "-"));

  // And a whole one, unchanged.
  let now = JSON.parse<Node>("{\"id\":\"c\",\"name\":\"third\",\"source\":\"y\",\"cases\":\"z\"}");
  console.log(now.id + " " + (now.source ?? "-") + " " + (now.cases ?? "-"));
}

main();
