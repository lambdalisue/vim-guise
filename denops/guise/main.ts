import type { Denops } from "https://deno.land/x/denops_std@v1.8.0/mod.ts";
import * as batch from "https://deno.land/x/denops_std@v1.8.0/batch/mod.ts";
import * as helper from "https://deno.land/x/denops_std@v1.8.0/helper/mod.ts";
import * as vars from "https://deno.land/x/denops_std@v1.8.0/variable/mod.ts";
import * as unknownutil from "https://deno.land/x/unknownutil@v1.1.0/mod.ts";
import {
  Session as VimSession,
} from "https://deno.land/x/vim_channel_command@v0.7.1/mod.ts";
import {
  Dispatcher,
  Session as NvimSession,
} from "https://deno.land/x/msgpack_rpc@v3.1.0/mod.ts";
import * as editor from "./editor.ts";

const GUISE_VIM_ADDRESS = "GUISE_VIM_ADDRESS";
const GUISE_NVIM_ADDRESS = "GUISE_NVIM_ADDRESS";

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
    await vars.e.set(denops, "EDITOR", config.progpath);
  }
}

async function getConfig(denops: Denops): Promise<Config> {
  const [progpath, disableVim, disableNeovim, disableEditor] = await batch
    .gather(denops, async (denops) => {
      await vars.v.get(denops, "progpath", "");
      await vars.g.get(denops, "guise#disable_vim", 0);
      await vars.g.get(denops, "guise#disable_neovim", 0);
      await vars.g.get(denops, "guise#disable_editor", 0);
    });
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

    edit(filename: unknown) {
      unknownutil.ensureString(filename);
      return editor.edit(denops, filename);
    },

    error(
      exception: unknown,
      throwpoint: unknown,
    ) {
      unknownutil.ensureString(exception);
      unknownutil.ensureString(throwpoint);
      const message = [exception, throwpoint].join("\n");
      return helper.echo(denops, message);
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

function handleVim(denops: Denops, conn: Deno.Conn): Promise<void> {
  const dispatcher = getDispatcher(denops);
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

function handleNeovim(denops: Denops, conn: Deno.Conn): Promise<void> {
  const dispatcher = getDispatcher(denops);
  const session = new NvimSession(conn, conn, dispatcher);
  return session.waitClosed();
}
