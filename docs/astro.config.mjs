// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';
import starlightLlmsTxt from 'starlight-llms-txt';
import { apiLinks } from './src/plugins/api-links.mjs';

export default defineConfig({
	site: 'https://zypy.jokelbaf.dev',
	integrations: [
		apiLinks({ index: new URL('./src/api-links.json', import.meta.url) }),
		starlight({
			title: 'ZyPy',
			logo: { light: './src/assets/logo-light.svg', dark: './src/assets/logo-dark.svg' },
			description: 'Write Python extensions in Zig, and use Python from Zig programs.',
			plugins: [starlightLlmsTxt()],
			customCss: ['./src/styles/theme.css'],
			social: [{ icon: 'github', label: 'GitHub', href: 'https://github.com/jokelbaf/ZyPy' }],
			editLink: { baseUrl: 'https://github.com/jokelbaf/ZyPy/edit/master/docs/' },
			sidebar: [
				{
					label: 'Getting started',
					items: ['getting-started/introduction', 'getting-started/installation', 'getting-started/first-project'],
				},
				{
					label: 'Concepts',
					items: ['concepts/how-it-works', 'concepts/ownership', 'concepts/errors'],
				},
				{
					label: 'Writing extensions',
					items: [
						'extensions/functions',
						'extensions/conversions',
						'extensions/objects',
						'extensions/iterables',
						'extensions/buffers',
						{
							label: 'Classes',
							items: [
								'extensions/classes/defining',
								'extensions/classes/special-methods',
								'extensions/classes/instances',
								'extensions/classes/inheritance',
							],
						},
						'extensions/enums',
						'extensions/modules',
						'extensions/exceptions',
					],
				},
				{
					label: 'Using Python from Zig',
					items: ['python/calling-python', 'python/threads', 'python/embedding'],
				},
				{
					label: 'Building and packaging',
					items: ['building/packaging', 'building/type-stubs', 'building/build-zig', 'building/c-api', 'building/debugging'],
				},
				{
					label: 'Reference',
					items: ['reference/cli', 'reference/pyproject', 'reference/limitations'],
				},
				{
					label: 'API reference',
					items: [{ autogenerate: { directory: 'api' } }],
				},
			],
		}),
	],
});
