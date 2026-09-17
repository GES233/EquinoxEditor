import { expect, test } from '@playwright/test';

test('音高草稿、存活、越界降级、重写与移除完整闭环', async ({ page }) => {
  const errors: string[] = [];
  page.on('pageerror', (error) => errors.push(error.message));
  await page.goto('/');
  await expect(page.getByText('已连接', { exact: true })).toBeVisible();
  await page.getByRole('button', { name: '编辑音高调校', exact: true }).click();
  if (await page.getByRole('button', { name: '移除音高调校', exact: true }).isEnabled()) {
    await page.getByRole('button', { name: '移除音高调校', exact: true }).click();
    await page.getByRole('button', { name: '编辑音高调校', exact: true }).click();
  }
  const before = await page.getByTestId('history-pin').textContent();
  await page.getByLabel('控制点 2 音高', { exact: true }).fill('62.25');
  await expect(page.getByTestId('history-pin')).toHaveText(before!);
  const point = page.getByRole('button', { name: '拖动控制点 2', exact: true });
  const box = (await point.boundingBox())!;
  await page.mouse.move(box.x + 5, box.y + 5);
  await page.mouse.down(); await page.mouse.move(box.x - 40, box.y - 20);
  await page.keyboard.press('Escape'); await page.mouse.up();
  await expect(page.getByLabel('控制点 2 音高', { exact: true })).toHaveValue('62.25');
  await expect(page.getByTestId('history-pin')).toHaveText(before!);
  await page.getByRole('button', { name: '应用音高调校', exact: true }).click();
  await expect(page.getByTestId('history-pin')).not.toHaveText(before!);
  await expect(page.getByTestId('pitch-line')).toBeVisible();
  await page.getByRole('button', { name: '检查当前版本' }).click();
  await expect(page.getByTestId('check-state')).toHaveText('当前版本检查通过');
  const lyric = await page.getByLabel('歌词', { exact: true }).inputValue();
  await page.getByLabel('歌词', { exact: true }).fill(lyric === '改词' ? '再改' : '改词');
  await page.getByRole('button', { name: '应用音符修改' }).click();
  await expect(page.getByTestId('check-state')).toHaveText('当前版本尚未检查');
  await page.getByRole('button', { name: '检查当前版本' }).click();
  await expect(page.getByTestId('check-state')).toHaveText('当前版本检查通过');
  await page.getByRole('button', { name: '编辑音高调校', exact: true }).click();
  await expect(page.getByLabel('控制点 2 音高', { exact: true })).toHaveValue('62.25');
  await page.getByRole('button', { name: '移除音高调校', exact: true }).click();
  await expect(page.getByTestId('pitch-line')).toHaveCount(0);
  await page.getByRole('button', { name: '编辑音高调校', exact: true }).click();
  await page.getByLabel('控制点 2 偏移', { exact: true }).fill('600');
  await page.getByRole('button', { name: '应用音高调校', exact: true }).click();
  await page.getByRole('button', { name: '检查当前版本' }).click();
  await expect(page.getByRole('button', { name: '音高调校需要处理', exact: true })).toBeVisible();
  await page.getByRole('button', { name: '音高调校需要处理', exact: true }).click();
  const conflictPin = await page.getByTestId('history-pin').textContent();
  await page.getByRole('button', { name: '尝试沿用调校' }).click();
  await expect(page.getByText('无法沿用：原调校已保留，请重新编辑或移除。')).toBeVisible();
  await expect(page.getByTestId('history-pin')).toHaveText(conflictPin!);
  await page.getByRole('button', { name: '重新编辑调校' }).click();
  await page.getByLabel('控制点 2 偏移', { exact: true }).fill('360');
  await page.getByRole('button', { name: '应用音高调校', exact: true }).click();
  await page.getByRole('button', { name: '检查当前版本' }).click();
  await expect(page.getByTestId('check-state')).toHaveText('当前版本检查通过');
  await page.screenshot({ path: 'test-results/pitch-workspace.png', fullPage: true });
  await page.getByRole('button', { name: '编辑音高调校', exact: true }).click();
  await page.getByRole('button', { name: '移除音高调校', exact: true }).click();
  await expect(page.getByTestId('pitch-line')).toHaveCount(0);
  await page.getByRole('button', { name: '撤销', exact: true }).click();
  // 水平 SVG 折线的几何高度为 0，Playwright 的可见性判断不包含 stroke。
  await expect(page.getByTestId('pitch-line')).toHaveCount(1);
  await page.getByRole('button', { name: '重做', exact: true }).click();
  await expect(page.getByTestId('pitch-line')).toHaveCount(0);
  expect(errors).toEqual([]);
});

test('点列表单空值、重复值不提交，清空后仍可加点', async ({ page }) => {
  await page.goto('/');
  await page.getByRole('button', { name: '编辑音高调校', exact: true }).click();
  await page.getByLabel('控制点 2 音高', { exact: true }).fill('');
  await expect(page.getByRole('button', { name: '应用音高调校', exact: true })).toBeDisabled();
  await page.getByLabel('控制点 2 音高', { exact: true }).fill('62');
  await page.getByLabel('控制点 2 偏移', { exact: true }).fill('0');
  await expect(page.getByText('控制点偏移不能重复')).toBeVisible();
  await expect(page.getByRole('button', { name: '应用音高调校', exact: true })).toBeDisabled();
  await page.getByRole('button', { name: '删除控制点 2', exact: true }).click();
  await page.getByRole('button', { name: '删除控制点 1', exact: true }).click();
  await page.getByRole('button', { name: '添加控制点', exact: true }).click();
  await expect(page.getByLabel('控制点 1 音高', { exact: true })).toHaveValue('60');
});

test('旧版本检查延迟返回时不覆盖新版本', async ({ page }) => {
  let release: (() => void) | undefined;
  await page.routeWebSocket('**/socket/websocket**', (ws) => {
    const server = ws.connectToServer();
    let checkRef: string | null = null;
    ws.onMessage((message) => {
      const data = JSON.parse(String(message));
      if (data[3] === 'check') checkRef = data[1];
      server.send(message);
    });
    server.onMessage((message) => {
      const data = JSON.parse(String(message));
      if (checkRef && data[1] === checkRef && data[3] === 'phx_reply') release = () => ws.send(message);
      else ws.send(message);
    });
  });
  await page.goto('/');
  await page.getByRole('button', { name: '检查当前版本' }).click();
  await expect.poll(() => !!release).toBe(true);
  const lyric = await page.getByLabel('歌词', { exact: true }).inputValue();
  await page.getByLabel('歌词', { exact: true }).fill(lyric === '新版本' ? '更新' : '新版本');
  await page.getByRole('button', { name: '应用音符修改' }).click();
  await expect(page.getByTestId('check-state')).toHaveText('当前版本尚未检查');
  release!();
  await expect(page.getByRole('button', { name: '检查当前版本' })).toBeEnabled();
  await expect(page.getByTestId('check-state')).toHaveText('当前版本尚未检查');
});
