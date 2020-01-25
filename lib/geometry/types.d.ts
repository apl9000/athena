export type Circle = {
	radius: number;
	area: number;
	circumference: number;
};

export type CircleArgs = Partial<Circle>;

export type Square = {
	length: number;
	area: number;
	perimeter;
};

export type SquareArgs = Partial<Square>;
