10 REM SEG$ (LANGUAGE.MD 6.2)
20 LET H$ = "HELLO"
30 PRINT "["; SEG$(H$, 2, 3); "]"
40 PRINT "["; SEG$(H$, 0, 2); "]"
50 PRINT "["; SEG$(H$, 4, 99); "]"
60 PRINT "["; SEG$(H$, 3, 2); "]"
70 PRINT "["; SEG$(H$, 6, 9); "]"
80 PRINT "["; SEG$(H$, 2.5, 3.49); "]"
90 PRINT "["; SEG$("", 1, 1); "]"
100 PRINT LEN(SEG$("AB  ", 3, 4))
110 PRINT "["; SEG$(H$, -1E30, 1E30); "]"
120 PRINT "["; SEG$(SEG$(H$, 2, 5), 2, 3); "]"
130 LET H$ = SEG$(H$, 1, 1)
140 PRINT H$
150 DEF FNX(N)
160 LET A$ = "WORLD"
170 LET FNX = N
180 FNEND
190 LET A$ = "HELLO"
200 PRINT SEG$(A$, FNX(1), 2)
210 PRINT SEG$("ABCDEF", 1.5, 2.5)
220 END
