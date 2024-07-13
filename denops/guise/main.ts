import type { Denops } from "https://deno.land/x/denops_std@v6.5.1/mod.ts";
import * as batch from "https://deno.land/x/denops_std@v6.5.1/batch/mod.ts";
import * as helper from "https://deno.land/x/denops_std@v6.5.1/helper/mod.ts";
import * as vars from "https://deno.land/x/denops_std@v6.5.1/variable/mod.ts";
import * as unknownutil from "https://deno.land/x/unknownutil@v3.18.1/mod.ts";
import {
  Session as VimSession,
} from "https://deno.land/x/vim_channel_command@v3.1.1/mod.ts";
import {
  Dispatcher,
  Session as NvimSession,
} from "https://deno.land/x/msgpack_rpc@v4.0.1/mod.ts";
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
    let args: string[];
    if (denops.meta.host === "vim") {
      args = [
        "-R", // Readonly
        "-N", // No compatible
        "-n", // No swapfile
        "-X", // Do not try connecting to the X server
        // Ex mode
        // On Windows, when `-e` is specified, calls via non-terminal (e.g. job or Deno)
        // hang for some reason.
        // However, if you do not use `-e`, you will get the following warnings
        //
        //  Vim: Warning: Output is not to a terminal
        //  Vim: Warning: Input is not from a terminal
        //
        // For now, we don't know how to deal with these warnings, so we are treating
        // them as specifications.
        ...(denops.meta.platform === "windows" ? [] : ["-e"]),
        // Silent batch mode
        // On Windows, if `-s` is specified, for some reason, it immediately terminates
        // and does not function properly.
        ...(denops.meta.platform === "windows" ? [] : ["-s"]),
      ];
    } else {
      args = [
        "-R", // Readonly
        "-n", // No swapfile
        "--headless",
      ];
    }
    const progpath = denops.meta.platform === "windows"
      ? `"${config.progpath}"`
      : `'${config.progpath}'`;
    await vars.e.set(
      denops,
      "EDITOR",
      `${progpath} ${args.join(" ")}`,
    );
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
      unknownutil.assertString(filename);
      return editor.edit(denops, filename);
    },

    error(
      exception: unknown,
      throwpoint: unknown,
    ) {
      unknownutil.assertString(exception);
      unknownutil.assertString(throwpoint);
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
