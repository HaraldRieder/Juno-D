// Juno_Dynamik.cpp : Definiert den Einsprungpunkt für die Konsolenanwendung.
//

#include "stdafx.h"
#include "stdlib.h"

/* ============= volumes transformer ================= */

static const int BENDPOINT_1 = 7 ; // (7/7)
static int x2,y2 ;

static const int MAX_VOLUMES = 128 ; // MIDI Anschlagdynamikwerte 0..127

/* ============= output ================= */

// Juno-D sendet keine Dynamikwerte < 7, deswegen tritt Abschnitt 1 nie in Erscheinung.
void print_dynamics()
{
	for (int x = 0 ; x < MAX_VOLUMES ; x++)
	{
		int y = x ;
		if (x > BENDPOINT_1)
		{
			if (x < x2)
			{
				/* Abschnitt 2 */
				y = ((y2-7)*x + (x2-y2)*7) / (x2-7) ;
			}
			else
			{
				/* Abschnitt 3 */
				y = ((127-y2)*x + (y2-x2)*127) / (127-x2) ;
			}
		}
		/* Abschnitt 1 */
		if (x == 0)
			printf("%u" , y);
		else
			printf(",%u" , y);
	}
}

/* ============= usage ================= */

int usage(const char *prog)
{
	printf("Aufruf: %s x2 y2\n\n", prog) ;
	printf("  x2  8..126 x-Wert des 2. Punktes\n") ;
	printf("  y2  8..126 y-Wert des 2. Punktes\n") ;
	printf("\nDieses Programm berechnet eine Transformationstabelle fuer MIDI-Dynamikwerte."
		   " Mit x werden die Eingangs- und mit y die transformierten Werte bezeichnet."
		   " Die Tabelle besteht aus 3 linearen Abschnitten."
		   " In Abschnitt 1 x=0..7 wird die Dynamik nicht transformiert, da Juno-D"
		   " keine Dynamikwerte unterhalb von 7 sendet."
		   " Abschnitt 2 geht von (x1=7/y1=7) bis zum einzugebenden Punkt (x2/y2)."
		   " Abschnitt 3 geht von (x2/y2) bis zum Maximum (127/127).");
	return 1;
}

/* ============= main ================= */

int main(int argc, char* argv[])
{
	// 1. Programmargumente uebernehmen und pruefen

#if 1
	if (argc != 3)
		return usage(argv[0]) ;
	x2 = atoi(argv[1]) ;
	y2 = atoi(argv[2]) ;	
#else
	x2 = 100 ;
	y2 = 115 ;	
#endif

	if (x2 <= BENDPOINT_1 || x2 >= MAX_VOLUMES - 1)
	{
		printf("Wert %u ungueltig!", x2) ;
		exit(1);
	}
	if (y2 <= BENDPOINT_1 || y2 >= MAX_VOLUMES - 1)
	{
		printf("Wert %u ungueltig!", y2) ;
		exit(1);
	}

	// Werte ausgeben fuer MIDI-Dynamiktransformation
	print_dynamics();
	printf("\n");

	return 0;
}

