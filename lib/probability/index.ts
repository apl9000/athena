// Probability density function (PDF)
export const uniformPdf = (x: number): number => {
	return x < 1 && x >= 0 ? 1 : 0;
};

// Cumulative distribution function (CDF)
export const uniformCdf = (x: number): number => (x < 0 ? 0 : x < 1 ? x : 1);

export const normalPdf = (x: number, mu = 0, sigma = 0): number => {
	return (
		(1 / Math.sqrt(2 * Math.PI)) *
		(Math.exp((-1 * (x - mu)) ** 2) / (2 * sigma ** 2))
	);
};

export const normalCdf = (x: number, mu = 0, sigma = 1): number => {
  return (1 )
}