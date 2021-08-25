import type { Denops } from "https://deno.land/x/denops_std@v1.7.3/mod.ts";
import * as helper from "https://deno.land/x/denops_std@v1.7.3/helper/mod.ts";
import * as vars from "https://deno.land/x/denops_std@v1.7.3/variable/mod.ts";
import * as unknownutil from "https://deno.land/x/unknownutil@v1.1.0/mod.ts";
import {
  Session as VimSession,
} from "https://deno.land/x/vim_channel_command@v0.7.1/mod.ts#^";
import { Session as NvimSession } from "https://deno.land/x/msgpack_rpc@v3.1.0/mod.ts#^";
import * as editor from "./editor.ts";

const GUISE_VIM_ADDRESS = "GUISE_VIM_ADDRESS";
const GUISE_NVIM_ADDRESS = "GUISE_NVIM_ADDRESS";

export function main(denops: Denops): Promise<void> {
  Promise.race([
    listenVim(denops),
    listenNvim(denops),
  ]);
  return Promise.resolve();
}

class Dispatcher {
  #denops: Denops;

  constructor(denops: Denops) {
    this.#denops = denops;
  }

  async open(): Promise<void> {
    await editor.open(this.#denops);
  }

  async edit(filename: unknown): Promise<void> {
    unknownutil.ensureString(filename);
    await editor.edit(this.#denops, filename);
  }

  async error(
    exception: unknown,
    throwpoint: unknown,
  ): Promise<void> {
    unknownutil.ensureString(exception);
    unknownutil.ensureString(throwpoint);
    const message = [exception, throwpoint].join("\n");
    await helper.echo(this.#denops, message);
  }
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
    handleVim(denops, conn);
  }
}

function handleVim(denops: Denops, conn: Deno.Conn): Promise<void> {
  const dispatcher = new Dispatcher(denops);
  const session = new VimSession(conn, conn, async (message) => {
    const [msgid, expr] = message;
    const [fn, ...args] = expr as [string, ...unknown[]];
    try {
      // deno-lint-ignore no-explicit-any
      await (dispatcher as any)[fn](...args);
      await session.reply(msgid, "");
    } catch (e) {
      await session.reply(msgid, e.toString());
    }
  });
  return session.waitClosed();
}

async function listenNvim(denops: Denops): Promise<void> {
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
    handleNvim(denops, conn);
  }
}

function handleNvim(denops: Denops, conn: Deno.Conn): Promise<void> {
  const dispatcher = new Dispatcher(denops);
  const session = new NvimSession(conn, conn, {
    open() {
      return dispatcher.open();
    },
    edit(filename) {
      return dispatcher.edit(filename);
    },
    error(exception, throwpoint) {
      return dispatcher.error(exception, throwpoint);
    },
  });
  return session.waitClosed();
}
