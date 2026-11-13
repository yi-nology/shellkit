<script setup lang="ts">
// 导航栏三段配色选择器：白 / 黑 / 跟随系统。
// 状态与主题消费方共享（../useDarkMode 的模块单例），写入即落盘 + 应用 data-theme。
// 图标用内联 SVG（语言中性），文案随 locale 切换；窄屏只留图标。
import { computed } from 'vue'
import { useRouteLocale } from 'vuepress/client'
import { colorMode, type ColorMode } from '../useDarkMode'

const routeLocale = useRouteLocale()
const isEn = computed(() => routeLocale.value.startsWith('/en'))

const modes = [
  { key: 'light' as ColorMode, zh: '白', en: 'Light', titleZh: '浅色主题', titleEn: 'Light theme' },
  { key: 'dark' as ColorMode, zh: '黑', en: 'Dark', titleZh: '深色主题', titleEn: 'Dark theme' },
  { key: 'auto' as ColorMode, zh: '系统', en: 'System', titleZh: '跟随系统', titleEn: 'Follow system' },
]

const label = (m: (typeof modes)[number]): string => (isEn.value ? m.en : m.zh)
const title = (m: (typeof modes)[number]): string => (isEn.value ? m.titleEn : m.titleZh)
const pick = (key: ColorMode): void => {
  colorMode.value = key
}
</script>

<template>
  <div
    class="sk-color-mode"
    role="group"
    :aria-label="isEn ? 'Color mode' : '配色模式'"
  >
    <button
      v-for="m in modes"
      :key="m.key"
      type="button"
      class="sk-color-mode-btn"
      :class="{ active: colorMode === m.key }"
      :title="title(m)"
      :aria-pressed="colorMode === m.key"
      @click="pick(m.key)"
    >
      <svg v-if="m.key === 'light'" class="sk-color-mode-icon" viewBox="0 0 16 16" aria-hidden="true">
        <circle cx="8" cy="8" r="3.2" fill="currentColor" />
        <g stroke="currentColor" stroke-width="1.4" stroke-linecap="round">
          <line x1="8" y1="1.5" x2="8" y2="3.2" />
          <line x1="8" y1="12.8" x2="8" y2="14.5" />
          <line x1="1.5" y1="8" x2="3.2" y2="8" />
          <line x1="12.8" y1="8" x2="14.5" y2="8" />
          <line x1="3.4" y1="3.4" x2="4.6" y2="4.6" />
          <line x1="11.4" y1="11.4" x2="12.6" y2="12.6" />
          <line x1="3.4" y1="12.6" x2="4.6" y2="11.4" />
          <line x1="11.4" y1="4.6" x2="12.6" y2="3.4" />
        </g>
      </svg>
      <svg v-else-if="m.key === 'dark'" class="sk-color-mode-icon" viewBox="0 0 16 16" aria-hidden="true">
        <path
          d="M13.5 9.8A5.8 5.8 0 0 1 6.2 2.5 5.8 5.8 0 1 0 13.5 9.8Z"
          fill="currentColor"
        />
      </svg>
      <svg v-else class="sk-color-mode-icon" viewBox="0 0 16 16" aria-hidden="true">
        <rect x="1.5" y="2.5" width="13" height="9" rx="1.5" fill="none" stroke="currentColor" stroke-width="1.4" />
        <line x1="5.5" y1="14" x2="10.5" y2="14" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" />
        <line x1="8" y1="11.5" x2="8" y2="14" stroke="currentColor" stroke-width="1.4" />
      </svg>
      <span class="sk-color-mode-label">{{ label(m) }}</span>
    </button>
  </div>
</template>

<style scoped lang="scss">
.sk-color-mode {
  display: flex;
  align-items: center;
  gap: 2px;
  margin-inline-start: 1rem;
  padding: 2px;
  border: 1px solid var(--vp-c-divider);
  border-radius: 999px;
  background: var(--vp-c-bg-soft);
}

.sk-color-mode-btn {
  display: flex;
  align-items: center;
  gap: 4px;
  padding: 3px 9px;
  border: 0;
  border-radius: 999px;
  background: transparent;
  color: var(--vp-c-text-2);
  font-size: 12px;
  line-height: 1;
  cursor: pointer;
  transition: background-color 0.15s, color 0.15s;
}

.sk-color-mode-btn:hover {
  background: var(--vp-c-accent-soft);
  color: var(--vp-c-text);
}

// 当前选中段：主色实底。浅色 #0969da / 深色 #1f6feb 都压得住白字
.sk-color-mode-btn.active {
  background: var(--vp-c-accent-bg);
  color: #fff;
}

.sk-color-mode-icon {
  width: 14px;
  height: 14px;
  flex: none;
}

// 窄屏只留图标（导航栏右侧空间有限，文案是次要信息）
@media (max-width: 640px) {
  .sk-color-mode {
    margin-inline-start: 0.5rem;
  }
  .sk-color-mode-label {
    display: none;
  }
  .sk-color-mode-btn {
    padding: 4px;
  }
}

@media print {
  .sk-color-mode {
    display: none;
  }
}
</style>
