import { getCollection } from 'astro:content';
import type { APIRoute, GetStaticPaths } from 'astro';

// Serve every docs page as raw markdown at <url>.md - the convention
// AI agents probe for (Mintlify/GitBook emit the same endpoints).
export const getStaticPaths: GetStaticPaths = async () => {
	const docs = await getCollection('docs');
	return docs
		.filter((doc) => doc.body && doc.id !== 'index')
		.map((doc) => ({ params: { slug: doc.id }, props: { doc } }));
};

export const GET: APIRoute = ({ props }) => {
	const { doc } = props;
	const description = doc.data.description ? `> ${doc.data.description}\n\n` : '';
	return new Response(`# ${doc.data.title}\n\n${description}${doc.body}`, {
		headers: { 'Content-Type': 'text/markdown; charset=utf-8' },
	});
};
