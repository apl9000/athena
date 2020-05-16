export const normalApproximationToBinomial = (
	n: number,
	p: number
): [number, number] => {
	//  Returns mu and sigma corresponding to a Binomial(n, p)
	const mu = p * n;
	const sigma = Math.sqrt(p * (1 - p) * n);
	return [mu, sigma];
};
