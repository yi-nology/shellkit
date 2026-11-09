<script setup lang="ts">
import { computed } from 'vue'
import { withBase } from 'vuepress/client'

const props = defineProps<{
  src: string
  caption?: string
}>()

const url = computed(() => withBase(props.src))
</script>

<template>
  <figure class="sk-shot">
    <img :src="url" :alt="caption ?? ''" loading="lazy">
    <figcaption v-if="caption">{{ caption }}</figcaption>
  </figure>
</template>
