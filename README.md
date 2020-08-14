# msa_get_grades

A Perl program to retrieve grades from the [Learning Management System](https://k12hub.blackbaud.com/blackbaud-learning-management-system)
owed by [Blackbaud](https://www.blackbaud.com/), sold as software as a service (SaaS) and with installations that are hosted at domain
names like &lt;school&gt;.myschoolapp.com.

The program is primarily intended for use in a cron job and, in my case, it is used to email a daily snapshot of our kids'
grades to my wife and me. The output of the program is as follows, but with actual grades instead of 0.00:

	Fred (Upper School Grade 10, 2020-2021, 1st Semester):
	  -   0.00: AP COMP PRINCIPLES - 1 (E)                     Art Grosman
	  -   0.00: CHEMISTRY - 1 (D)                          Michelle Piliod
	  -   0.00: H ENGLISH 10 - 2 (G)                         Henry Dortman
	  -   0.00: H GEOMETRY - 2 (F)                         Allison Grulert
	  -   0.00: MODERN WORLD - 1 (C)                      Heather Viabadco
	  -   0.00: SPANISH 3 - 1 (A)                       Francisco Calderon
	  -   0.00: Study Hall - 3 (B)                        Heather Viabadco
	  -   0.00: US Homeroom - 10C (HR)                  Nathaniel Smithson
	
	
	Jill (Middle School Grade 6, 2020-2021, 1st Semester):
	  -   0.00: ART 6 - 1 (D)                                 Anna Branson
	  -   0.00: ENGLISH 6 - 1 (C)                          Rachel Roberson
	  -   0.00: FUNDAMENTALS OF PRE-ALGEBRA - 1 (B)              Tina Bach
	  -   0.00: HISTORY 6 - 1 (A)                            Jimmy Burkson
	  -   0.00: MS Homeroom - 06A (HR)                           Tina Bach
	  -   0.00: PE 6_P.D. - 1 (E)                               Brad Smith
	  -   0.00: SCIENCE 6 - 2 (F)                                Tina Bach
	  -   0.00: WORLD LANGUAGE/FOUNDATIONS - 1 (G)        Caroline Levvers
	
	
	This data was pulled from https://<yourschool>.myschoolapp.com
