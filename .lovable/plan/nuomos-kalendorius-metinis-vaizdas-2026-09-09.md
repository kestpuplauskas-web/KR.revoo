# Nuomos kalendorius (metinis vaizdas)

Perkeliame „Demo-revoo“ rezervacijų kalendoriaus idėją į ilgalaikę nuomą, bet stulpeliai — ne dienos, o **mėnesiai**: viename ekrane matomi visi pasirinkti metai (12 mėnesių).

## Ką pamatys Rapolas

Naujas puslapis „Kalendorius“ meniu grupėje „Portfelis“, iškart po „Butai“.

- Kairėje — butų sąrašas (sugrupuotas pagal pastatą), viršuje — 12 mėnesių eilė.
- Kiekviena nuomos sutartis rodoma kaip spalvota juosta, besitęsianti per mėnesius, kuriuos ji apima. Juostos kraštas atitinka tikslią dieną mėnesio viduje, todėl iš karto matosi, ar sutartis baigiasi mėnesio pradžioje ar pabaigoje.
- Sutartis be pabaigos datos (neterminuota) tęsiasi iki metų galo su rodykle, rodančia, kad ji tęsiasi toliau.
- Spalvos pagal sutarties būseną: aktyvi, besibaigianti (įteiktas įspėjimas), juodraštis, pasibaigusi, nutraukta. Legenda po įrankių juosta.
- Butai be sutarties tam laikui rodomi kaip laisvi; remontuojami / neaktyvūs butai — atskiru atspalviu visai eilei.
- Įrankių juosta: metai atgal / „Šie metai“ / metai pirmyn, paieška pagal butą arba nuomininką, filtras pagal pastatą, žymė „rodyti tik užimtus“.
- Einamasis mėnuo pažymėtas vertikalia linija.
- Viršuje — trumpa suvestinė: kiek butų užimta šiandien, kiek sutarčių baigiasi tais metais.

## Paspaudimai

- Paspaudus juostą — atsidaro langas su sutarties duomenimis: butas, nuomininkas, laikotarpis, mėnesinis nuomos mokestis, depozitas, mokėjimo diena, būsena. Iš jo — nuorodos į butą ir į nuomininką.
- Paspaudus tuščią mėnesį — pereinama į to buto kortelę, kur sutartis kuriama esamu būdu.
- Vilkimo/perkėlimo **nėra**. Sutartis yra finansinis dokumentas: datos keičiamos tik per esamus veiksmus (įspėjimas, pratęsimas, nutraukimas), kad nebūtų atsitiktinių pakeitimų.

## Telefone

Telefone metų tinklelis slenkamas horizontaliai (butų stulpelis prilipęs kairėje), mėnesiai rodomi sutrumpintai. Nieko naujo nekuriama — tas pats komponentas.

## Techninė dalis

- Naujas maršrutas `src/routes/_authenticated/admin.calendar.tsx`; nuoroda `src/routes/_authenticated/admin.tsx` „portfolio“ grupėje.
- Naujas komponentas `src/components/admin/LeasesYearGantt.tsx` — grynas atvaizdavimas, be duomenų gavimo. Rodo eilutes per CSS grid (`200px + repeat(12, 1fr)`), juostos pozicionuojamos procentais pagal mėnesio dieną (`monthIndex + (day-1)/daysInMonth`).
- Duomenys: esami `listUnits`, `listBuildings` ir `listLeases` per `useServerFn` + `useQuery`. Į `listLeases` prireikus pridedamas datų persidengimo filtras (`start_date <= metų galas` ir (`end_date is null` arba `end_date >= metų pradžia`)) — naujų serverio funkcijų nekuriame, jokių DB migracijų.
- Būsenų sąrašas imamas iš `LEASE_STATUSES` (`src/lib/rental.ts`), spalvos — per esamus dizaino tokenus, be hardcodintų `bg-white`/hex reikšmių.
- Visi tekstai per i18n: nauja `rental.calendar.*` sekcija `lt.json` ir `en.json` (LT ir EN kartu).
- Patikrinimas: `tsgo` be klaidų, build be klaidų, puslapis atsidaro prisijungus, patikrinama juostų padėtis su realiomis sutartimis.
- `roadmap.md` papildomas šiuo darbu.
