import { readFileSync, statSync } from 'node:fs';

/**
 * Link the first inline mention of each API item per section using the JSON link index.
 * Skip headings and existing links.
 */
export function apiLinks({ index }) {
	return {
		name: 'zypy-api-links',
		hooks: {
			'astro:config:setup': ({ config }) => {
				config.markdown.processor.options.mdastPlugins.push(linkPlugin(index));
			},
		},
	};
}

function linkPlugin(index) {
	let cache = { mtime: 0, links: {} };

	function links() {
		try {
			const mtime = statSync(index).mtimeMs;
			if (mtime !== cache.mtime) cache = { mtime, links: JSON.parse(readFileSync(index, 'utf8')) };
		} catch {
			cache = { mtime: 0, links: {} };
		}
		return cache.links;
	}

	return {
		name: 'zypy-api-links',
		before(root, ctx) {
			const known = links();
			const linked = new Set();

			function visit(node) {
				for (const child of node.children ?? []) {
					if (child.type === 'heading') {
						if (child.depth <= 3) linked.clear();
						continue;
					}
					if (child.type === 'link' || child.type === 'linkReference') continue;
					if (child.type !== 'inlineCode') {
						visit(child);
						continue;
					}

					const url = resolve(known, child.value);
					if (!url || linked.has(url)) continue;

					linked.add(url);
					ctx.replaceNode(child, { type: 'link', url, children: [{ type: 'inlineCode', value: child.value }] });
				}
			}

			visit(root);
		},
	};
}

function resolve(known, text) {
	if (!/^(py|zypy)\.[A-Za-z_]/.test(text)) return null;

	let name = text;
	while (/\([^()]*\)/.test(name)) name = name.replace(/\([^()]*\)/g, '');
	const parts = name.match(/^[\w.]+/)[0].split('.').filter(Boolean);
	for (let end = parts.length; end >= 2; end--) {
		const url = known[parts.slice(0, end).join('.')];
		if (url) return url;
	}
	return null;
}
