import type { Denops } from "https://deno.land/x/denops_std@v1.7.3/mod.ts";
import * as autocmd from "https://deno.land/x/denops_std@v1.7.3/autocmd/mod.ts";
import * as anonymous from "https://deno.land/x/denops_std@v1.7.3/anonymous/mod.ts";
import * as option from "https://deno.land/x/denops_std@v1.7.3/option/mod.ts";
import * as batch from "https://deno.land/x/denops_std@v1.7.3/batch/mod.ts";
import { deferred } from "https://deno.land/std@0.104.0/async/mod.ts";
import * as bufname from "./lib/bufname.ts";

export async function open(denops: Denops): Promise<void> {
  await denops.cmd("tabnew");
}

export async function edit(denops: Denops, filename: string): Promise<void> {
  const waiter = deferred<void>();
  const [waiterId] = anonymous.once(
    denops,
    () => {
      waiter.resolve();
    },
  );
  const [writerId] = anonymous.add(
    denops,
    async () => {
      await denops.cmd("call writefile(getline(1, '$'), filename)", {
        filename,
      });
      await option.modified.set(denops, false);
    },
  );
  await batch.batch(denops, async (denops) => {
    await denops.cmd("tabedit `=filename`", {
      filename: bufname.format({
        scheme: "guise",
        path: filename,
      }),
    });
    await read(denops, filename);
    await option.buftype.set(denops, "acwrite");
    await option.bufhidden.set(denops, "wipe");
    await autocmd.group(denops, "guise_internal", (helper) => {
      helper.remove("*", "<buffer>");
      helper.define(
        "BufWriteCmd",
        "<buffer>",
        `call denops#request('${denops.name}', '${writerId}', [])`,
      );
      helper.define(
        ["BufWipeout", "VimLeave"],
        "<buffer>",
        `call denops#request('${denops.name}', '${waiterId}', [])`,
        {
          once: true,
        },
      );
    });
  });
  await waiter;
}

async function read(denops: Denops, filename: string): Promise<void> {
  await batch.batch(denops, async (denops) => {
    await option.undolevels.set(denops, -1);
    await denops.cmd("read `=filename`", { filename });
    await denops.cmd("0delete");
    await option.modified.set(denops, false);
    await option.undolevels.reset(denops);
  });
}
