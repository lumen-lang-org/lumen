function sumToAThousand(): int {
  let total = 0;
  let i = 0;
  while (i < 1000) {
    total = total + i;
    i = i + 1;
  }
  return total;
}

async function main(): Promise<void> {
  let plain = await Worker.run(sumToAThousand);
  console.log("plain " + `${plain}`);

  let base: int = 100;
  let scale: int = 3;
  let captured = await Worker.run((): int => base * scale + 7);
  console.log("captured " + `${captured}`);

  let a = Worker.run(sumToAThousand);
  let b = Worker.run(sumToAThousand);
  let ra = await a;
  let rb = await b;
  console.log("concurrent " + `${ra}` + "," + `${rb}`);
}
main();
