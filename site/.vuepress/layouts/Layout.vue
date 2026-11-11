<script setup lang="ts">
// 自定义 Layout：只为了在每页底部挂一个 llms.txt 入口。
//
// 为什么不能只靠 theme.footer：这个主题（2.0.0-rc.31）没有全局页脚组件，
// footer 只服务于首页（VPHomeFooter 读 frontmatter.footer）。配置项写进去
// 不会报错、也不会渲染 —— 属于「以为做了，其实没做」的那一类。
//
// 所以这里包一层主题自带的 Layout，把入口塞进 page-bottom 插槽：
// 正文列的底部就是每页都有的页脚位置。
import Parent from '@vuepress/theme-default/layouts/Layout.vue'

const LLMS_URL = 'https://yi-nology.github.io/shellkit/llms.txt'
</script>

<template>
  <Parent>
    <template #page-bottom>
      <footer class="sk-footer">
        <a class="sk-footer-link" :href="LLMS_URL" target="_blank" rel="noopener noreferrer">
          给 AI 直读：llms.txt
        </a>
        <span class="sk-footer-note">一个文件读完整个站点的地图</span>
      </footer>
    </template>
  </Parent>
</template>

<style scoped>
.sk-footer {
  display: flex;
  flex-wrap: wrap;
  gap: 0.5rem 0.75rem;
  align-items: baseline;
  margin-top: 2.5rem;
  padding-top: 1rem;
  border-top: 1px solid var(--vp-c-divider);
  font-size: 13px;
  color: var(--vp-c-text-2);
}

.sk-footer-link {
  font-weight: 600;
  color: var(--vp-c-brand-1);
  text-decoration: none;
}

.sk-footer-link:hover {
  text-decoration: underline;
}

.sk-footer-note {
  color: var(--vp-c-text-3);
}
</style>
