import type { Denops } from "jsr:@denops/std@^8.2.0";
import { collect } from "jsr:@denops/std@^8.2.0/batch";
import { echo } from "jsr:@denops/std@^8.2.0/helper";
import * as vars from "jsr:@denops/std@^8.2.0/variable";
import { assert, is } from "jsr:@core/unknownutil@^4.3.0";
import { Session as VimSession } from "jsr:@denops/vim-channel-command@^4.0.2";
import type { Dispatcher } from "jsr:@lambdalisue/messagepack-rpc@^2.4.1";
import { Session as NvimSession } from "jsr:@lambdalisue/messagepack-rpc@^2.4.1";
import { pop, push } from "jsr:@lambdalisue/streamtools@^1.0.0";
import * as path from "jsr:@std/path@^1.0.0";
import * as editor from "./editor.ts";

const GUISE_VIM_ADDRESS = "GUISE_VIM_ADDRESS";
const GUISE_NVIM_ADDRESS = "GUISE_NVIM_ADDRESS";
const GUISE_PROXY_ADDRESS = "GUISE_PROXY_ADDRESS";

type Config = {
  progpath: string;
  disableVim: boolean;
  disableNeovim: boolean;
  disableEditor: boolean;
};

export async function main(denops: Denops): Promise<void> {
  const config = await getConfig(denops);
  if (!config.disableVim) {
    listenVim(denops).catch((e) => {
      console.error(`[guise] Unexpected error occurred for Vim listener: ${e}`);
    });
  }
  if (!config.disableNeovim) {
    listenNeovim(denops).catch((e) => {
      console.error(
        `[guise] Unexpected error occurred for Neovim listener: ${e}`,
      );
    });
  }
  if (!config.disableEditor) {
    listenProxy(denops).catch((e) => {
      console.error(
        `[guise] Unexpected error occurred for Proxy listener: ${e}`,
      );
    });
  }
}

async function getConfig(denops: Denops): Promise<Config> {
  const [progpath, disableVim, disableNeovim, disableEditor] = await collect(
    denops,
    (denops) => [
      vars.v.get(denops, "progpath", ""),
      vars.g.get(denops, "guise#disable_vim", 0),
      vars.g.get(denops, "guise#disable_neovim", 0),
      vars.g.get(denops, "guise#disable_editor", 0),
    ],
  );
  return {
    progpath: progpath as string,
    disableVim: !!disableVim,
    disableNeovim: !!disableNeovim,
    disableEditor: !!disableEditor,
  };
}

function getDispatcher(denops: Denops): Dispatcher {
  return {
    open() {
      return editor.open(denops);
    },

    edit(filename: unknown): Promise<void> {
      assert(filename, is.String);
      return editor.edit(denops, filename);
    },

    error(
      exception: unknown,
      throwpoint: unknown,
    ) {
      assert(exception, is.String);
      assert(throwpoint, is.String);
      const message = [exception, throwpoint].join("\n");
      return echo(denops, message);
    },
  };
}

async function listenVim(denops: Denops): Promise<void> {
  const listener = Deno.listen({
    hostname: "127.0.0.1",
    port: 0, // Automatically select free port
  });
  const addr = listener.addr as Deno.NetAddr;
  await vars.e.set(
    denops,
    GUISE_VIM_ADDRESS,
    `${addr.hostname}:${addr.port}`,
  );
  for await (const conn of listener) {
    handleVim(denops, conn).catch((e) => {
      console.error(`[guise] Unexpected error occurred: ${e}`);
    });
  }
}

async function listenNeovim(denops: Denops): Promise<void> {
  const listener = Deno.listen({
    hostname: "127.0.0.1",
    port: 0, // Automatically select free port
  });
  const addr = listener.addr as Deno.NetAddr;
  await vars.e.set(
    denops,
    GUISE_NVIM_ADDRESS,
    `${addr.hostname}:${addr.port}`,
  );
  for await (const conn of listener) {
    handleNeovim(denops, conn).catch((e) => {
      console.error(`[guise] Unexpected error occurred: ${e}`);
    });
  }
}

async function handleVim(denops: Denops, conn: Deno.Conn): Promise<void> {
  const dispatcher = getDispatcher(denops);
  const session = new VimSession(conn.readable, conn.writable);
  session.onMessage = async (message) => {
    const [msgid, expr] = message;
    const [fn, ...args] = expr as [string, ...unknown[]];
    try {
      // deno-lint-ignore no-explicit-any
      await (dispatcher as any)[fn](...args);
      await session.send([msgid, ""]);
    } catch (e) {
      await session.send([msgid, e instanceof Error ? e.message : String(e)]);
    }
  };
  session.start();
  await session.wait();
}

async function handleNeovim(denops: Denops, conn: Deno.Conn): Promise<void> {
  const dispatcher = getDispatcher(denops);
  const session = new NvimSession(conn.readable, conn.writable);
  session.dispatcher = dispatcher;
  session.start();
  await session.wait();
}

const recordPattern = /^([^:]+):(.*)$/;
const encoder = new TextEncoder();
const decoder = new TextDecoder();

async function listenProxy(denops: Denops): Promise<void> {
  const listener = Deno.listen({
    hostname: "127.0.0.1",
    port: 0, // Automatically select free port
  });
  const addr = listener.addr as Deno.NetAddr;
  const script = path.fromFileUrl(new URL("proxy.ts", import.meta.url));
  const denoFlags =
    "--no-check --allow-env=GUISE_PROXY_ADDRESS,GUISE_DEBUG --allow-net=127.0.0.1 --allow-write";
  await vars.e.set(
    denops,
    GUISE_PROXY_ADDRESS,
    JSON.stringify({ hostname: addr.hostname, port: addr.port }),
  );
  await vars.e.set(
    denops,
    "EDITOR",
    denops.meta.platform === "windows"
      ? `deno run ${denoFlags} "${script}"`
      : `deno run ${denoFlags} '${script}'`,
  );
  for await (const conn of listener) {
    handleProxy(denops, conn).catch((e) => {
      console.error(`[guise] Unexpected error occurred: ${e}`);
    });
  }
}

async function handleProxy(denops: Denops, conn: Deno.Conn): Promise<void> {
  try {
    const data = await pop(conn.readable);
    if (!data) {
      await push(conn.writable, encoder.encode("err:No data received"));
      return;
    }
    const record = decoder.decode(data);
    const m = record.match(recordPattern);
    if (!m) {
      await push(
        conn.writable,
        encoder.encode(`err:Unexpected record '${record}'`),
      );
      return;
    }
    const [name, value] = m.slice(1);
    switch (name) {
      case "open":
        await editor.open(denops);
        await push(conn.writable, encoder.encode("ok:"));
        break;
      case "edit":
        await editor.edit(denops, value);
        await push(conn.writable, encoder.encode("ok:"));
        break;
      default:
        await push(
          conn.writable,
          encoder.encode(`err:Unknown command '${name}'`),
        );
    }
  } catch (e) {
    await push(conn.writable, encoder.encode(`err:${e}`));
  } finally {
    conn.close();
  }
}
