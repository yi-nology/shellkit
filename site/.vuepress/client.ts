// VuePress 2 不会自动注册 .vuepress/components/ 下的组件（那是 VuePress 1 的行为）。
// 不注册的话，markdown 里的 <ShotFigure /> 会被当成未知元素静默丢弃 —— 构建照样 rc=0，
// 但页面上就是没有图。所以必须在这里显式注册。
import { defineClientConfig } from 'vuepress/client'
import ShotFigure from './components/ShotFigure.vue'

export default defineClientConfig({
  enhance({ app }) {
    app.component('ShotFigure', ShotFigure)
  }
})
