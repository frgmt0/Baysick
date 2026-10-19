10 REM PRECEDENCE: ^ BEFORE * / BEFORE + -, LEFT TO RIGHT WITHIN A LEVEL
20 PRINT 2 + 3 * 4, (2 + 3) * 4, 10 - 4 - 3, 10 - (4 - 3)
30 PRINT 24 / 4 / 2, 24 / (4 / 2), 2 * 3 / 4, 7 / 2 * 2
40 PRINT 2 ^ 3 ^ 2, 2 ^ (3 ^ 2), 2 * 3 ^ 2, (2 * 3) ^ 2
50 PRINT -2 ^ 2, (-2) ^ 2, -3 * 2 + 1, - (3 + 4)
60 PRINT +5, 1 + 2 * 3 ^ 2 / 6 - 4
70 LET A = 3
80 LET B = 4
90 PRINT SQR(A*A + B*B), A - B / A, (A - B) / A
100 END
