10 DIM A(3)
20 LET I = 1
30 CALL "S": X, A(I), 2 * X, B$, "Q"
40 END
50 SUB "S": P, Q, R, S$, T$
60 DEF FNA(Y) = Y + P
70 CALL "S": P, (Q), FNA(R), S$ & T$, SEG$(T$, 1, 1)
80 SUBEND
