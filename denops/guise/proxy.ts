#!/usr/bin/env -S deno run --no-check --allow-env=GUISE_PROXY_ADDRESS --allow-net=127.0.0.1
import { pop, push } from "jsr:@lambdalisue/streamtools@^1.0.0";
import { ensure, is } from "jsr:@core/unknownutil@^4.3.0";

const DEBUG_FILE = Deno.env.get("GUISE_DEBUG");

function debug(msg: string) {
  if (DEBUG_FILE) {
    Deno.writeTextFileSync(DEBUG_FILE, msg + "\n", { append: true });
  }
}

const resultPattern = /^([^:]+):(.*)$/;

const addr = JSON.parse(Deno.env.get("GUISE_PROXY_ADDRESS") ?? "null");
if (!addr) {
  throw new Error("GUISE_PROXY_ADDRESS environment variable is required");
}

debug(`[guise:proxy] args: ${JSON.stringify(Deno.args)}`);
debug(`[guise:proxy] addr: ${JSON.stringify(addr)}`);

const encoder = new TextEncoder();
const decoder = new TextDecoder();

const conn = await Deno.connect(addr);

if (Deno.args.length === 0) {
  // Open scratch buffer
  debug("[guise:proxy] sending: open:");
  await push(conn.writable, encoder.encode("open:"));
} else {
  // Edit files
  for (const filename of Deno.args) {
    debug(`[guise:proxy] sending: edit:${filename}`);
    await push(conn.writable, encoder.encode(`edit:${filename}`));
  }
}

debug("[guise:proxy] waiting for response...");
const result = decoder.decode(
  ensure(await pop(conn.readable), is.InstanceOf(Uint8Array)),
);
debug(`[guise:proxy] received: ${result}`);
conn.close();

const m = result.match(resultPattern);
if (!m) {
  throw new Error(`Unexpected result '${result}' is received`);
}

const [status, value] = m.slice(1);
switch (status) {
  case "ok":
    debug("[guise:proxy] exiting with code 0");
    Deno.exit(0);
    break;
  case "cancel":
    debug("[guise:proxy] exiting with code 1 (cancel)");
    Deno.exit(1);
    break;
  case "err":
    debug(`[guise:proxy] exiting with code 1 (err: ${value})`);
    console.error(value);
    Deno.exit(1);
    break;
  default:
    debug(`[guise:proxy] unexpected status: ${status}`);
    throw new Error(`Unexpected status '${status}' is received`);
}
