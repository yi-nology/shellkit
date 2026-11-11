// VuePress 2 不会自动注册 .vuepress/components/ 下的组件（那是 VuePress 1 的行为）。
// 不注册的话，markdown 里的 <ShotFigure /> 会被当成未知元素静默丢弃 —— 构建照样 rc=0，
// 但页面上就是没有图。所以必须在这里显式注册。
//
// 同时把主题的 Layout 换成我们的：主题这个版本没有全局页脚组件，
// theme.footer 写进去不报错也不渲染（属于「以为做了，其实没做」），
// 而「页脚挂一处 llms.txt 入口」是这一版的目标之一。
// 主题的 clientConfig 先注册 Layout，站点这份后注册 —— 同名后者覆盖前者。
import { defineClientConfig } from 'vuepress/client'
import ShotFigure from './components/ShotFigure.vue'
import Layout from './layouts/Layout.vue'

export default defineClientConfig({
  enhance({ app }) {
    app.component('ShotFigure', ShotFigure)
  },
  layouts: {
    Layout,
  },
})
