import { viteBundler } from '@vuepress/bundler-vite'
import { defaultTheme } from '@vuepress/theme-default'
import { searchPlugin } from '@vuepress/plugin-search'
import { defineUserConfig } from 'vuepress'

const REPO = 'https://github.com/yi-nology/shellkit'

// 与 tools/shdoc.sh 的 MODULES 同序：读者按「先有什么、后有什么」看
const MODULES = [
  'error', 'i18n', 'log', 'str', 'validate', 'fs', 'os', 'trap', 'run',
  'retry', 'lock', 'net', 'config', 'prompt', 'cli',
]

const zhGuideSidebar = [
  { text: '开始', collapsible: true, children: ['/guide/index.md', '/guide/installation.md', '/guide/quickstart.md'] },
  { text: '核心概念', collapsible: true, children: ['/guide/conventions.md', '/guide/bash32.md', '/guide/modules.md'] },
  { text: '常见任务', collapsible: true, children: ['/guide/cookbook.md', '/guide/cli.md', '/guide/i18n.md', '/guide/testing.md', '/guide/ai.md'] },
  { text: '进阶', collapsible: true, children: ['/guide/examples.md', '/guide/migrating.md', '/guide/releasing.md', '/guide/contributing.md'] },
  { text: '排错', collapsible: true, children: ['/guide/troubleshooting.md', '/guide/faq.md'] },
]

const enGuideSidebar = [
  { text: 'Getting started', collapsible: true, children: ['/en/guide/index.md', '/en/guide/installation.md', '/en/guide/quickstart.md'] },
  { text: 'Core concepts', collapsible: true, children: ['/en/guide/conventions.md', '/en/guide/bash32.md', '/en/guide/modules.md'] },
  { text: 'Common tasks', collapsible: true, children: ['/en/guide/cookbook.md', '/en/guide/cli.md', '/en/guide/i18n.md', '/en/guide/testing.md', '/en/guide/ai.md'] },
  { text: 'Going further', collapsible: true, children: ['/en/guide/examples.md', '/en/guide/migrating.md', '/en/guide/releasing.md', '/en/guide/contributing.md'] },
  { text: 'Troubleshooting', collapsible: true, children: ['/en/guide/troubleshooting.md', '/en/guide/faq.md'] },
]

const referenceChildren = (prefix: string): string[] => [
  prefix + '/reference/index.md',
  ...MODULES.map((m) => prefix + '/reference/' + m + '.md'),
]

export default defineUserConfig({
  lang: 'zh-CN',
  title: 'shellkit',
  description: '约束清晰的 Bash 库、脚手架生成器与 CLI 框架。基线 Bash 3.2+，stdout 只给数据，日志一律 stderr。',
  base: '/shellkit/',

  head: [
    ['link', { rel: 'icon', href: '/shellkit/favicon.svg', type: 'image/svg+xml' }],
    ['meta', { name: 'theme-color', content: '#0b0e13' }],
    ['meta', { name: 'author', content: 'yi-nology' }],
    ['meta', { property: 'og:type', content: 'website' }],
    ['meta', { property: 'og:site_name', content: 'shellkit' }],
  ],

  locales: {
    '/': {
      lang: 'zh-CN',
      title: 'shellkit',
      description: '写运维 shell 的起点：Bash 库、脚手架生成器、CLI 框架。',
    },
    '/en/': {
      lang: 'en-US',
      title: 'shellkit',
      description: 'A Bash library, project generator and CLI framework with explicit constraints.',
    },
  },

  bundler: viteBundler(),

  theme: defaultTheme({
    logo: '/logo.svg',
    colorMode: 'dark',
    colorModeSwitch: true,
    lastUpdated: true,
    contributors: false,
    editLink: false,
    sidebarDepth: 2,
    docsRepo: 'yi-nology/shellkit',
    docsBranch: 'main',
    docsDir: 'site',

    locales: {
      '/': {
        selectLanguageName: '简体中文',
        selectLanguageText: '语言',
        selectLanguageAriaLabel: '选择语言',
        notFound: ['页面不存在', '这一页要么改名了，要么还没写。'],
        backToHome: '回到首页',
        lastUpdatedText: '最后更新',
        navbar: [
          { text: '指南', link: '/guide/index.md' },
          { text: 'API 参考', link: '/reference/index.md' },
          { text: '示例', link: '/guide/examples.md' },
          { text: '发布产物', link: REPO + '/releases' },
          { text: 'GitHub', link: REPO },
        ],
        sidebar: {
          '/guide/': zhGuideSidebar,
          '/reference/': [{ text: 'API 参考', collapsible: false, children: referenceChildren('') }],
        },
      },
      '/en/': {
        selectLanguageName: 'English',
        selectLanguageText: 'Languages',
        selectLanguageAriaLabel: 'Select language',
        notFound: ['Page not found', 'This page was renamed or has not been written yet.'],
        backToHome: 'Back to home',
        lastUpdatedText: 'Last updated',
        navbar: [
          { text: 'Guide', link: '/en/guide/index.md' },
          { text: 'API reference', link: '/en/reference/index.md' },
          { text: 'Examples', link: '/en/guide/examples.md' },
          { text: 'Releases', link: REPO + '/releases' },
          { text: 'GitHub', link: REPO },
        ],
        sidebar: {
          '/en/guide/': enGuideSidebar,
          '/en/reference/': [{ text: 'API reference', collapsible: false, children: referenceChildren('/en') }],
        },
      },
    },
  }),

  plugins: [
    searchPlugin({
      locales: {
        '/': { placeholder: '搜索文档' },
        '/en/': { placeholder: 'Search docs' },
      },
    }),
  ],
})
