10 LET A$ = "HELLO"
20 LET B$ = SEG$(A$, 2, 3) & "X" & A$
30 PRINT POS(A$, "L"); POS(B$, A$, 2)
40 END
