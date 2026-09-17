import { expect, test } from '@playwright/test';

test('模型输出草稿、时长到音高漂移、沿用、再次告警与移除', async ({ page }) => {
  const errors: string[] = [];
  page.on('pageerror', (error) => errors.push(error.message));
  await page.goto('/');
  await page.getByLabel('歌词', { exact: true }).fill('la');
  await page.getByRole('button', { name: '应用音符修改' }).click();
  await page.getByRole('button', { name: '提取当前模型输出', exact: true }).click();
  await expect(page.getByTestId('output-pitch-curve')).toBeVisible();
  const before = await page.getByTestId('history-pin').textContent();
  await page.getByLabel('模型音高点 2 MIDI', { exact: true }).fill('64.25');
  await expect(page.getByTestId('history-pin')).toHaveText(before!);
  const circle = page.getByTestId('output-pitch-curve').locator('circle').nth(1);
  const box = (await circle.boundingBox())!;
  await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
  await page.mouse.down(); await page.mouse.move(box.x - 20, box.y - 10);
  await page.keyboard.press('Escape'); await page.mouse.up();
  await expect(page.getByLabel('模型音高点 2 MIDI', { exact: true })).toHaveValue('64.25');
  await page.getByRole('button', { name: '应用模型音高', exact: true }).click();
  await expect(page.getByTestId('history-pin')).not.toHaveText(before!);
  await expect(page.getByRole('button', { name: '移除模型音高', exact: true })).toBeVisible();
  const first = page.getByLabel('音素 1 帧长', { exact: true });
  const second = page.getByLabel('音素 2 帧长', { exact: true });
  const a = Number(await first.inputValue()), b = Number(await second.inputValue());
  await first.fill('');
  await expect(page.getByRole('button', { name: '应用音素时长', exact: true })).toBeDisabled();
  await first.fill(String(a + 1)); await second.fill(String(b - 1));
  await page.getByRole('button', { name: '应用音素时长', exact: true }).click();
  await expect(page.getByTestId('output-issues')).toBeVisible();
  // 非模态冲突：仍能编辑谱面；关闭提示不会替用户重签。
  await expect(page.getByLabel('歌词', { exact: true })).toBeEnabled();
  await page.getByRole('button', { name: '沿用音高修改', exact: true }).click();
  await expect(page.getByTestId('output-issues')).toHaveCount(0);
  await first.fill(String(a + 2)); await second.fill(String(b - 2));
  await page.getByRole('button', { name: '应用音素时长', exact: true }).click();
  await expect(page.getByTestId('output-issues')).toBeVisible();
  await page.screenshot({ path: 'test-results/output-conflict.png', fullPage: true });
  await page.getByTestId('output-issues').getByRole('button', { name: '移除模型音高', exact: true }).click();
  await page.getByRole('button', { name: '提取当前模型输出', exact: true }).click();
  await page.getByRole('button', { name: '移除音素时长', exact: true }).click();
  await page.getByRole('button', { name: '检查当前版本', exact: true }).click();
  await expect(page.getByTestId('check-state')).toHaveText('当前版本检查通过');
  expect(errors).toEqual([]);
});

test('提取期间继续编辑，延迟返回的旧输出不会变成新底料', async ({ page }) => {
  let release: (() => void) | undefined;
  await page.routeWebSocket('**/socket/websocket**', (ws) => {
    const server = ws.connectToServer();
    let ref: string | null = null;
    ws.onMessage((message) => {
      const data = JSON.parse(String(message));
      if (data[3] === 'extract_output') ref = data[1];
      server.send(message);
    });
    server.onMessage((message) => {
      const data = JSON.parse(String(message));
      if (ref && data[1] === ref && data[3] === 'phx_reply') release = () => ws.send(message);
      else ws.send(message);
    });
  });
  await page.goto('/');
  await page.getByRole('button', { name: '提取当前模型输出', exact: true }).click();
  await expect.poll(() => !!release).toBe(true);
  await page.getByLabel('歌词', { exact: true }).fill('延迟提取');
  await page.getByRole('button', { name: '应用音符修改' }).click();
  release!();
  await expect(page.getByRole('button', { name: '提取当前模型输出', exact: true })).toBeEnabled();
  await expect(page.getByTestId('output-pitch-curve')).toHaveCount(0);
});
