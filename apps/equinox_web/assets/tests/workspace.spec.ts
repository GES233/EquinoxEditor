import { expect, test } from '@playwright/test';

test('音符编辑、撤销、重做、刷新及声库绑定进入真实工程', async ({ page }) => {
  const errors: string[] = [];
  page.on('pageerror', (error) => errors.push(error.message));
  await page.goto('/');
  await expect(page.getByText('已连接', { exact: true })).toBeVisible();
  const originalLyric = await page.getByLabel('歌词', { exact: true }).inputValue();
  const nextLyric = originalLyric === '你好' ? '啦' : '你好';
  const originalPin = await page.getByTestId('history-pin').textContent();
  await page.getByLabel('歌词', { exact: true }).fill(nextLyric);
  await page.getByRole('button', { name: '应用音符修改' }).click();
  await expect(page.getByTestId('history-pin')).not.toHaveText(originalPin!);
  await expect(page.getByRole('button', { name: new RegExp(`音符 ${nextLyric}`) })).toBeVisible();
  await page.getByRole('button', { name: '撤销', exact: true }).click();
  await expect(page.getByLabel('歌词', { exact: true })).toHaveValue(originalLyric);
  await expect(page.getByTestId('history-pin')).toHaveText(originalPin!);
  await page.getByRole('button', { name: '重做', exact: true }).click();
  await expect(page.getByLabel('歌词', { exact: true })).toHaveValue(nextLyric);
  await page.reload();
  await expect(page.getByLabel('歌词', { exact: true })).toHaveValue(nextLyric);

  const select = page.getByLabel('选择声库', { exact: true });
  const originalVoicebank = await select.inputValue();
  const options = await select.locator('option').evaluateAll((items) => items.map((item) => (item as HTMLOptionElement).value).filter(Boolean));
  const selected = options.find((id) => id !== originalVoicebank)!;
  await select.selectOption(selected);
  await page.getByRole('button', { name: '应用声库', exact: true }).click();
  await expect(page.getByRole('button', { name: '应用声库', exact: true })).toBeDisabled();
  await page.reload();
  await expect(select).toHaveValue(selected);
  await page.getByRole('button', { name: '撤销', exact: true }).click();
  await expect(select).toHaveValue(originalVoicebank);
  // 现有 History 的 undo 按全局 seq 遍历；下一场景从最新节点开始，避免把
  // 分支来源关系误当成 undo 的下一步。
  await page.getByRole('button', { name: '重做', exact: true }).click();
  await expect(select).toHaveValue(selected);
  await page.screenshot({ path: 'test-results/workspace.png', fullPage: true });
  expect(errors).toEqual([]);
});

test('拖动松手才提交，Esc 取消且不产生历史记录', async ({ page }) => {
  await page.goto('/');
  const note = page.getByRole('button', { name: /^音符 / });
  await expect(note).toBeVisible();
  const before = await page.getByTestId('history-pin').textContent();
  const box = (await note.boundingBox())!;
  await page.mouse.move(box.x + 30, box.y + 10);
  await page.mouse.down();
  await page.mouse.move(box.x + 78, box.y + 10);
  await expect(page.getByTestId('history-pin')).toHaveText(before!);
  await page.keyboard.press('Escape');
  await page.mouse.up();
  await expect(page.getByTestId('history-pin')).toHaveText(before!);
  await page.mouse.move(box.x + 30, box.y + 10);
  await page.mouse.down();
  await page.mouse.move(box.x + 78, box.y + 10);
  await page.mouse.up();
  await expect(page.getByTestId('history-pin')).not.toHaveText(before!);
  await page.getByRole('button', { name: '撤销', exact: true }).click();
  await expect(page.getByTestId('history-pin')).toHaveText(before!);
  await page.getByRole('button', { name: '重做', exact: true }).click();
  await expect(page.getByTestId('history-pin')).not.toHaveText(before!);
});

test('声库组件保持草稿与权威绑定分离并展示独立状态', async ({ page }) => {
  await page.goto('/?components');
  const normal = page.getByRole('region', { name: '正常样例', exact: true });
  await normal.getByLabel('选择声库', { exact: true }).selectOption('b');
  await normal.getByRole('button', { name: '应用声库' }).click();
  await expect(page.getByText('收到选择意图：b（未连接工程）')).toBeVisible();
  await expect(normal.getByText('演示声库 A', { exact: true })).toBeVisible();
  await page.getByRole('button', { name: '模拟权威绑定更新' }).click();
  await expect(normal.getByRole('button', { name: '应用声库' })).toBeDisabled();
  await expect(page.getByRole('region', { name: '缺失样例', exact: true }).getByRole('alert').first()).toBeVisible();
  await expect(page.getByRole('region', { name: '空样例', exact: true })).toContainText('没有可用的声库');
  await page.getByRole('region', { name: '错误样例', exact: true }).getByRole('button', { name: '重试' }).click();
  await expect(page.getByText('请求重新查询', { exact: true })).toBeVisible();
  await expect(page.getByRole('region', { name: '禁用样例', exact: true }).getByRole('combobox')).toBeDisabled();
});

test('另一个页面提交后同步快照，断线后重新连接恢复权威状态', async ({ page, context }) => {
  await page.goto('/');
  await expect(page.getByText('已连接', { exact: true })).toBeVisible();
  const other = await context.newPage();
  await other.goto('/');
  const original = await page.getByLabel('歌词', { exact: true }).inputValue();
  const next = original === '同步' ? '同声' : '同步';
  await other.getByLabel('歌词', { exact: true }).fill(next);
  await other.getByRole('button', { name: '应用音符修改' }).click();
  await expect(page.getByLabel('歌词', { exact: true })).toHaveValue(next);
  await context.setOffline(true);
  await expect(page.getByRole('button', { name: '撤销', exact: true })).toBeDisabled({ timeout: 45_000 });
  await context.setOffline(false);
  await expect(page.getByText('已连接', { exact: true })).toBeVisible();
  await expect(page.getByLabel('歌词', { exact: true })).toHaveValue(next);
  await page.getByLabel('歌词', { exact: true }).fill(original);
  await page.getByRole('button', { name: '应用音符修改' }).click();
  await other.close();
});
