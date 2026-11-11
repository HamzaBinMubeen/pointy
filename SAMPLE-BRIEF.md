# UI change notes — 11/11/2026, 3:14:57 PM

5 marks over 00:52 · viewport 1440×900 @2x

- `http://localhost:3000/dashboard`

> Each section is one spoken instruction plus the shapes drawn while saying it.
> Several marks under one **Said** are one change seen from several angles.
> Element names come from the running DOM; the line under a name is how to find it.
> Full detail is given the first time an element appears, not on every mention.
> Full-viewport screenshots are on disk as `NN.jpg` if a crop is not enough.

---

## Mark 1 · rectangle · 00:04

**Said** "these three cards are way too cramped, give them room and show if each number went up or down"

**Selected 3 elements**

1. `StatCard` — "Signups 1,284" · UsersIcon
   src/components/dashboard/StatCards.tsx:18 · in StatCards › Dashboard
2. `StatCard` — "Revenue $9.4k" · DollarSignIcon
   src/components/dashboard/StatCards.tsx:19 · in StatCards › Dashboard
3. `StatCard` — "Churn 1.2%" · ActivityIcon
   src/components/dashboard/StatCards.tsx:20 · in StatCards › Dashboard

Laid out today: grid of 3 columns inside `StatCards`, gap 6px (`gap-1.5`) · measured spacing 6px

![mark 1](01-crop.png)

on `http://localhost:3000/dashboard`

---

## Marks 2–3 · 00:17–00:21

**Said** "this heading is too quiet, make it big and give it a short line under it"

_2 marks drawn together; the words above cover all of them._

### 2 · arrow

**From** empty space inside `Dashboard` (8% across, 12% down)
   src/app/dashboard/page.tsx:9
**Points at** `h3` — "Your week"
   src/components/dashboard/Heading.tsx:6 · in Heading › Dashboard

Reads as: **calling attention to `h3`**

![mark 2](02-crop.png)

### 3 · point

**This element**

`h3` — "Your week"

![mark 3](03-crop.png)

---

## Mark 4 · circle · 00:33

**Said** "the chart is just grey blocks, label the days and make the best day stand out"

**Circled 1 element**

1. `WeekChart` — "Mon Tue Wed Thu Fri Sat Sun"
   src/components/dashboard/WeekChart.tsx:12 · in Dashboard

![mark 4](04-crop.png)

---

## Mark 5 · point · 00:46

**Said** "and upgrade should be the one thing you can't miss"

**This element**

`Button` — "Upgrade"
   src/components/nav/TopNav.tsx:27 · in TopNav › Dashboard

![mark 5](05-crop.png)
