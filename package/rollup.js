const { promisify } = require('util');
const fs = require('fs');
const path = require('path');
const rollup = require('rollup');
const uglifyJs = require('uglify-js');

const readFile = promisify(fs.readFile);
const writeFile = promisify(fs.writeFile);

const pkgName = 'matheticajs';
const libPath = path.join(__dirname, '..', 'lib');
const compiledPath = path.join(__dirname, 'dist');
const pkgNpmPath = path.join(__dirname, '..');

function removeSemicolons(code) {
	return code.replace(/;/g, '');
}

function removeLocalImportsExports(code) {
	const regex = /^\s*(import|export) .* from "\.\/.*"\s*;?\s*$/;
	return code
		.split('\n')
		.filter((line) => !regex.test(line))
		.join('\n')
		.trim();
}

async function generateTypes() {
	return [
		// removeLocalImportsExports(
		// 	(await readFile(path.join(libPath, 'index.d.ts'), 'utf-8')).trim()
		// ),
		// removeSemicolons(
		// 	removeLocalImportsExports(
		// 		await readFile(path.join(compiledPath, 'index.d.ts', 'utf-8')).trim()
		// 	)
		// )
	].join('\n\n');
}

async function build() {
	let bundle = await rollup.rollup({
		input: path.join(compiledPath, 'index.js')
	});

	let { output } = await bundle.generate({
		format: 'cjs',
		sourcemap: false
	});
	const code = output[0].code;
	let minified = uglifyJs.minify(code);
	if (minified.error) {
		throw minified.error;
	}

	await writeFile(path.join(pkgNpmPath, `${pkgName}.min.js`), minified.code);
	await writeFile(
		path.join(pkgNpmPath, `${pkgName}.d.ts`),
		await generateTypes()
	);
}

build().then(
	() => console.log('Jobs done.'),
	(err) => console.log(err.message, err.stack)
);
