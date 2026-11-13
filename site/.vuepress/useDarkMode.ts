// site/.vuepress/useDarkMode.ts
//
// 替换主题自带的 @theme/useDarkMode：主题只有「亮/暗」两态布尔切换，
// 需求是三态 —— 白 / 黑 / 跟随系统（默认跟随系统，选择记忆在 localStorage）。
// 由 config.ts 的 alias 把主题侧的 import 全部指到本文件：VuePress 的
// resolveAlias 按键长降序排序，长键 '@theme/useDarkMode' 必然优先于前缀 '@theme'。
//
// 与主题的契约（不能破）：
//   - setupDarkMode()：client config 的 setup() 里调用一次，负责 provide；
//   - useDarkMode()：返回可写的 boolean ref（亮/暗），品牌 logo、hero 等消费；
//   - 写入语义沿用主题：目标值 == 系统偏好 ⇒ 记 auto，否则记显式 dark/light。
import { darkModeSymbol } from '@vuepress/helper/client'
import { computed, inject, provide, ref, watch, type WritableComputedRef } from 'vue'

export type ColorMode = 'light' | 'dark' | 'auto'

/** 本选择器的存储键。旧键是主题两态时代的值（值域恰好一致），只读迁移。 */
const STORAGE_KEY = 'sk-color-mode'
const LEGACY_KEY = 'vuepress-color-scheme'

/** 三态选择（模块单例：选择器与主题消费方共享同一份状态） */
export const colorMode = ref<ColorMode>('auto')

/** 系统是否偏好深色；SSR 与首帧为 false，客户端 setup 时同步真实值 */
const systemDark = ref(false)

const isDark = computed(
  () => (colorMode.value === 'auto' ? systemDark.value : colorMode.value === 'dark'),
)

const applyTheme = (): void => {
  if (typeof document !== 'undefined') {
    document.documentElement.dataset.theme = isDark.value ? 'dark' : 'light'
  }
}

const readMode = (): ColorMode => {
  try {
    const current = localStorage.getItem(STORAGE_KEY)
    if (current === 'light' || current === 'dark' || current === 'auto') return current
    // 老访客：两态时代的选择直接迁移
    const legacy = localStorage.getItem(LEGACY_KEY)
    if (legacy === 'light' || legacy === 'dark' || legacy === 'auto') return legacy
  } catch {
    // localStorage 不可用（隐私模式等）：退回跟随系统
  }
  return 'auto'
}

const persist = (mode: ColorMode): void => {
  try {
    localStorage.setItem(STORAGE_KEY, mode)
  } catch {
    // 写失败不影响当前会话，下次进来重新默认即可
  }
}

export function setupDarkMode(): void {
  provide(
    darkModeSymbol,
    computed({
      get: () => isDark.value,
      // 与主题原语义一致：目标值等于系统偏好 ⇒ 存 auto，否则存显式值
      set: (value: boolean) => {
        colorMode.value = value === systemDark.value ? 'auto' : value ? 'dark' : 'light'
      },
    }) as WritableComputedRef<boolean>,
  )

  // SSR：provide 之外什么都不做（没有 window/localStorage/document）
  if (typeof window === 'undefined') return

  colorMode.value = readMode()

  const media = window.matchMedia('(prefers-color-scheme: dark)')
  systemDark.value = media.matches
  media.addEventListener('change', (event) => {
    systemDark.value = event.matches
  })

  // isDark 变（显式切换或系统翻转）就应用；immediate 兜住首帧
  watch(isDark, applyTheme, { immediate: true })
  watch(colorMode, (mode) => {
    persist(mode)
    applyTheme()
  })

  // 别的标签页改了选择，本标签页跟上
  window.addEventListener('storage', (event) => {
    if (event.key === STORAGE_KEY || event.key === LEGACY_KEY) {
      colorMode.value = readMode()
    }
  })
}

export function useDarkMode(): WritableComputedRef<boolean> {
  const injected = inject(darkModeSymbol, null)
  if (!injected) {
    throw new Error('useDarkMode() is called without provider.')
  }
  return injected
}
