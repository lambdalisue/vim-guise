import type { Denops } from "jsr:@denops/std@^8.2.0";
import { group } from "jsr:@denops/std@^8.2.0/autocmd";
import { add } from "jsr:@denops/std@^8.2.0/lambda";
import { batch, collect } from "jsr:@denops/std@^8.2.0/batch";
import { bufnr, win_getid } from "jsr:@denops/std@^8.2.0/function";
import * as vars from "jsr:@denops/std@^8.2.0/variable";
import { bufhidden } from "jsr:@denops/std@^8.2.0/option";

/**
 * Open a scratch buffer in a new tab page and wait the buffer is closed.
 */
export async function open(denops: Denops): Promise<void> {
  await denops.cmd("tabnew");
  const [winid, bufnrVal] = await collect(
    denops,
    (denops) => [
      win_getid(denops),
      bufnr(denops),
    ],
  );
  const auname = `guise_editor_${winid}_${bufnrVal}`;
  const { promise: waiter, resolve } = Promise.withResolvers<void>();
  const lambda = add(denops, async () => {
    await group(denops, auname, (helper) => {
      helper.remove();
    });
    lambda.dispose();
    resolve();
  });
  await batch(denops, async (denops) => {
    await bufhidden.setLocal(denops, "wipe");
    await group(denops, auname, (helper) => {
      helper.remove();
      helper.define(
        ["BufWipeout", "VimLeave"],
        "*",
        `call denops#request('${denops.name}', '${lambda.id}', [])`,
        {
          once: true,
        },
      );
    });
  });
  await waiter;
}

/**
 * Open a `filename` buffer in a new tab page and wait the buffer is closed.
 */
export async function edit(denops: Denops, filename: string): Promise<void> {
  const opener = await vars.g.get(denops, "guise_edit_opener", "tab drop");
  await denops.cmd(`silent noswapfile ${opener} \`=filename\``, {
    filename,
  });
  const [winid, bufnrVal] = await collect(
    denops,
    (denops) => [
      win_getid(denops),
      bufnr(denops),
    ],
  );
  const auname = `guise_editor_${winid}_${bufnrVal}`;
  const { promise: waiter, resolve } = Promise.withResolvers<void>();
  const lambda = add(denops, async () => {
    await group(denops, auname, (helper) => {
      helper.remove();
    });
    lambda.dispose();
    resolve();
  });
  await batch(denops, async (denops) => {
    await bufhidden.setLocal(denops, "wipe");
    await group(denops, auname, (helper) => {
      helper.remove();
      helper.define(
        ["BufWipeout", "VimLeave"],
        "*",
        `call denops#request('${denops.name}', '${lambda.id}', [])`,
        {
          once: true,
        },
      );
    });
  });
  await waiter;
}
