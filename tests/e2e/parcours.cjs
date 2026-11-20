// Parcours complet dans un vrai navigateur, à deux en même temps :
// l'organisatrice (espace organisateur) et une éducatrice (page de la journée).
// Lancer avec : python3 tests/e2e/lancer.py
const { chromium } = require("playwright");
const fs = require("fs");
const path = require("path");

const URL = process.env.APA_URL, ADMIN = process.env.APA_ADMIN;
const OUT = path.join(__dirname, "resultats"); fs.mkdirSync(OUT, { recursive: true });
let n = 0, ok = 0;
const pages = [];
function check(cond, quoi) { if (!cond) throw new Error("Vérification échouée : " + quoi); ok++; }
async function etape(nom, fn) {
  n++; const t0 = Date.now();
  try { await fn(); console.log(`  ✓ ${String(n).padStart(2)}. ${nom} (${Date.now() - t0} ms)`); }
  catch (e) {
    console.log(`  ✗ ${String(n).padStart(2)}. ${nom}\n      ${e.message.split("\n")[0]}`);
    for (const [i, p] of pages.entries()) await p.screenshot({ path: path.join(OUT, `echec-${n}-page${i + 1}.png`), fullPage: true }).catch(() => {});
    throw e;
  }
}
const texte = (p, sel) => p.textContent(sel).then(t => (t || "").trim());
const attendreTexte = (p, sel, morceau, timeout = 10000) =>
  p.waitForFunction(([s, m]) => (document.querySelector(s)?.textContent || "").includes(m), [sel, morceau], { timeout })
    .catch(async () => { throw new Error(`« ${morceau} » attendu dans ${sel}, trouvé : « ${await texte(p, sel).catch(() => "?")} »`); });

// Contraste WCAG AA de chaque texte visible et de chaque option de menu (même fonction que pour la page).
const AUDIT = () => {
  const parse = c => { const m = c.match(/rgba?\(([^)]+)\)/); if (!m) return [0, 0, 0, 0]; const v = m[1].split(/[ ,/]+/).filter(Boolean).map(Number); return [v[0], v[1], v[2], v[3] ?? 1]; };
  const over = (t, b) => { const a = t[3]; return [0, 1, 2].map(i => t[i] * a + b[i] * (1 - a)).concat(1); };
  const lum = c => { const f = x => { x /= 255; return x <= .03928 ? x / 12.92 : ((x + .055) / 1.055) ** 2.4; }; return .2126 * f(c[0]) + .7152 * f(c[1]) + .0722 * f(c[2]); };
  const ratio = (a, b) => { const [l1, l2] = [lum(a), lum(b)].sort((x, y) => y - x); return (l1 + .05) / (l2 + .05); };
  const bgOf = el => { const s = []; for (let e = el; e; e = e.parentElement) s.push(parse(getComputedStyle(e).backgroundColor)); let c = [255, 255, 255, 1]; for (const b of s.reverse()) if (b[3]) c = over(b, c); return c; };
  const out = [];
  const check = (el, txt, bg) => {
    const st = getComputedStyle(el), fg = over(parse(st.color), bg), r = ratio(fg, bg);
    const need = el.disabled ? 3 : parseFloat(st.fontSize) >= 18.5 || (parseFloat(st.fontSize) >= 14 && +st.fontWeight >= 700) ? 3 : 4.5;
    if (r < need) out.push(`${r.toFixed(2)} « ${txt.slice(0, 30)} »`);
  };
  const w = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
  for (let t; (t = w.nextNode());) { const el = t.parentElement; if (!t.textContent.trim() || el.closest("select,script,style") || !el.getClientRects().length) continue; check(el, t.textContent.trim(), bgOf(el)); }
  for (const s of document.querySelectorAll("select")) if (s.getClientRects().length) for (const o of s.options) { const ob = parse(getComputedStyle(o).backgroundColor); check(o, o.text, ob[3] ? over(ob, bgOf(s)) : bgOf(s)); }
  return [...new Set(out)];
};

(async () => {
  const browser = await chromium.launch();
  const opts = { viewport: { width: 1300, height: 900 }, acceptDownloads: true, locale: "fr-BE", timezoneId: "Europe/Brussels" };
  const orga = await (await browser.newContext({ ...opts, colorScheme: "dark" })).newPage();
  const edu = await (await browser.newContext({ ...opts, colorScheme: "light" })).newPage();
  pages.push(orga, edu);
  const erreurs = [];
  for (const p of pages) p.on("pageerror", e => erreurs.push(e.message));
  const admMsg = m => attendreTexte(orga, "#adm-msg", m);
  const two = async sel => { await orga.click(sel); await orga.click(sel); };   // boutons à double confirmation

  console.log("Parcours de bout en bout");
  try {
    await etape("Le menu montre les trois journées de départ, fermées", async () => {
      await edu.goto(URL); await edu.waitForSelector(".event");
      check((await edu.$$(".event")).length === 3, "3 journées");
      check((await texte(edu, "#events")).includes("Bientôt ouvertes"), "journées fermées");
      check(await edu.$('a[href="#organisateur"]'), "lien vers l'espace organisateur");
    });

    await etape("Espace organisateur : mauvais code refusé, bon code accepté", async () => {
      await orga.goto(URL + "#organisateur");
      await orga.fill("#adm-code", "pas-le-bon"); await orga.click("#adm-login-btn");
      await attendreTexte(orga, "#adm-login-msg", "incorrect");
      await orga.fill("#adm-code", ADMIN); await orga.click("#adm-login-btn");
      await orga.waitForSelector("#adm-app:not([hidden])");
      check((await orga.$$(".adm-j")).length === 3, "3 journées dans la liste");
    });

    await etape("Créer une journée vide (Couvin), avec identifiant proposé", async () => {
      await orga.click("#adm-new");
      await orga.fill("#nj-nom", "Journée APA de Couvin"); await orga.fill("#nj-date", "2027-06-10"); await orga.fill("#nj-lieu", "Couvin");
      check(await orga.inputValue("#nj-id") === "couvin-2027", "identifiant couvin-2027");
      await orga.click("#nj-save"); await admMsg("est créée");
      check((await texte(orga, ".adm-head h2")) === "Journée APA de Couvin", "journée sélectionnée");
    });

    await etape("Ajouter 4 ateliers, refuser un doublon", async () => {
      for (const [nom, lieu, cap] of [["Zumba", "P1", "16"], ["Massage", "P1", "4"], ["Boccia", "P1", "8"], ["Kinball", "P2", "16"]]) {
        await orga.fill('tr.new [data-f="nom"]', nom); await orga.fill('tr.new [data-f="lieu"]', lieu); await orga.fill('tr.new [data-f="cap"]', cap);
        await orga.click("[data-at-add]"); await admMsg(`« ${nom} » ajouté`);
      }
      await orga.fill('tr.new [data-f="nom"]', "zumba"); await orga.fill('tr.new [data-f="lieu"]', "P2"); await orga.fill('tr.new [data-f="cap"]', "5");
      await orga.click("[data-at-add]"); await admMsg("existe déjà");
      check((await orga.$$('#adm-ateliers tr[data-at]:not(.new)')).length === 4, "4 ateliers");
    });

    await etape("Générer les horaires (3 le matin, 2 l'après-midi) et les enregistrer", async () => {
      await orga.fill("#g-debut", "09:00"); await orga.fill("#g-dur", "20"); await orga.fill("#g-gap", "10");
      await orga.fill("#g-nm", "3"); await orga.fill("#g-reprise", "13:00"); await orga.fill("#g-na", "2");
      await orga.click("#g-go"); await attendreTexte(orga, "#h-msg", "5 tournantes, de 9h00 à 13h50");
      await orga.click("#h-save"); await admMsg("Horaires enregistrés (5 tournantes)");
    });

    await etape("Code d'accès : trop facile refusé, puis inscriptions ouvertes", async () => {
      await orga.fill("#ja-code", "couvin123"); await orga.click("#ja-save"); await admMsg("trop facile");
      await orga.fill("#ja-code", "sapin-brume-42"); await orga.click("#ja-save"); await admMsg("Code enregistré");
      await edu.goto(URL); await edu.waitForSelector(".event");
      check(await edu.$('a.event[href="#couvin-2027"]'), "Couvin ouverte dans le menu");
    });

    await etape("Éducatrice : mauvais code refusé, inscription de l'institution", async () => {
      await edu.click('a.event[href="#couvin-2027"]'); await edu.waitForSelector("#login:not([hidden])");
      await edu.fill("#code", "sapin-brume-00"); await edu.click("#login-btn"); await attendreTexte(edu, "#login-msg", "incorrect");
      await edu.fill("#code", "sapin-brume-42"); await edu.click("#login-btn"); await edu.waitForSelector("#reg-open");
      await edu.click("#reg-open");
      await edu.fill("#reg-nom", "Les Tilleuls"); await edu.fill("#reg-resp", "Marie"); await edu.fill("#reg-tel", "0470 12 34 56");
      await edu.fill("#reg-email", "marie@"); await edu.fill("#reg-places-n", "8"); await edu.fill("#reg-educ", "1");
      await edu.click("#reg-save"); await attendreTexte(edu, "#reg-msg", "e-mail invalide");
      await edu.fill("#reg-email", "marie@example.be"); await edu.click("#reg-save");
      await edu.waitForSelector("#inst-panel:not([hidden])"); await attendreTexte(edu, "#inst-msg", "est inscrite avec 8 places");
    });

    await etape("Former un groupe de 8 et l'envoyer dans un atelier de 4 (répartition)", async () => {
      await edu.click("#inst-groups"); await attendreTexte(edu, "#inst-msg", "1 groupe formé");
      await edu.click('[data-g="0"][data-t="1"]'); await edu.waitForSelector("#pal:not([hidden])");
      await edu.click('[data-pal-pick="massage"]'); await attendreTexte(edu, ".pal-warn", "Il ne reste que 4 places");
      await attendreTexte(edu, ".pal-count", "4/4");
      await edu.click("#pal-split-ok");
      const sugg = await edu.$$eval(".pal-sugg [data-pal-rest]", e => e.map(x => x.textContent.replace(/\s+/g, " ")));
      check(sugg[0].includes("voisin") && sugg.some(s => s.includes("Boccia")), "ateliers du même lieu proposés d'abord");
      await edu.click('[data-pal-rest="boccia"]');
      const lab = await edu.getAttribute('[data-g="0"][data-t="1"]', "aria-label");
      check(lab.includes("Massage 4") && lab.includes("Boccia 4"), "case divisée Massage 4 / Boccia 4 : " + lab);
    });

    await etape("Tout le groupe d'un coup au clavier, Annuler, puis enregistrer", async () => {
      await edu.click('[data-g="0"][data-t="2"]'); await edu.fill("#pal-q", "kin"); await edu.keyboard.press("Enter");
      check((await edu.getAttribute('[data-g="0"][data-t="2"]', "aria-label")).includes("Kinball"), "Kinball en T2");
      await edu.click('[data-g="0"][data-t="3"]'); await edu.click('[data-pal-pick="zumba"]');
      await edu.click("#inst-undo");
      check((await edu.getAttribute('[data-g="0"][data-t="3"]', "aria-label")).includes("à choisir"), "Annuler a retiré Zumba en T3");
      await edu.click("#inst-save"); await attendreTexte(edu, "#inst-msg", "8 participants enregistrés");
    });

    await etape("Ajouter à l'agenda : fichier .ics valide avec récapitulatif et PDF joint", async () => {
      const [dl] = await Promise.all([edu.waitForEvent("download"), edu.click("#inst-ics")]);
      const f = path.join(OUT, dl.suggestedFilename()); await dl.saveAs(f);
      const ics = fs.readFileSync(f, "utf8");
      check(dl.suggestedFilename() === "couvin-2027-les-tilleuls.ics", "nom du fichier");
      check(ics.includes("DTSTART;TZID=Europe/Brussels:20270610T090000") && ics.includes("DTEND;TZID=Europe/Brussels:20270610T135000"), "heures de début et de fin");
      check(ics.split("\r\n").every(l => Buffer.byteLength(l) <= 75), "lignes de 75 octets maximum");
      const desc = ics.replace(/\r\n /g, "");
      check(desc.includes("Massage (P1) : Participant") && desc.includes("Kinball (P2)"), "récapitulatif par groupe");
      const b64 = desc.split("\r\n").find(l => l.startsWith("ATTACH")).split(":").pop();
      check(Buffer.from(b64, "base64").subarray(0, 5).toString() === "%PDF-", "PDF joint valide");
      check(ics.includes("TRIGGER:-P1D"), "rappel la veille");
    });

    await etape("L'éducatrice commence une modification sans l'enregistrer", async () => {
      await edu.click('[data-g="0"][data-t="3"]'); await edu.click('[data-pal-pick="zumba"]');
      check((await texte(edu, "#inst-save")).startsWith("Enregistrer"), "brouillon en cours");
    });

    await etape("Organisatrice : impossible de baisser Massage sous ses 4 inscrits", async () => {
      await orga.click('[data-adm-j="couvin-2027"]'); await orga.waitForSelector('tr[data-at="massage"]');
      await attendreTexte(orga, 'tr[data-at="massage"] td:nth-child(5)', "4 · 4");   // 4 au plus sur une tournante, 4 au total
      await orga.fill('tr[data-at="massage"] [data-f="cap"]', "2"); await orga.click('tr[data-at="massage"] [data-at-save]');
      await admMsg("déjà 4 inscrits");
    });

    await etape("Organisatrice : supprimer Boccia montre l'institution touchée, puis confirme", async () => {
      await orga.click('tr[data-at="boccia"] [data-at-del]');
      await attendreTexte(orga, "#adm-ateliers tr.warn", "Les Tilleuls : 4");
      await orga.click('tr[data-at="boccia"] [data-at-del]'); await admMsg("4 inscriptions effacées");
      check(!(await orga.$('tr[data-at="boccia"]')), "Boccia supprimé");
    });

    await etape("Organisatrice : retirer la dernière tournante et renommer la journée", async () => {
      await orga.click("[data-h-del]"); await orga.click("#h-save"); await admMsg("4 tournantes");
      await orga.fill("#ji-nom", "Journée APA de Couvin (modifiée)"); await orga.click("#ji-save"); await admMsg("Informations enregistrées");
    });

    await etape("L'éducatrice voit les changements ; son brouillon est refusé proprement", async () => {
      await attendreTexte(edu, "#title", "(modifiée)", 15000);                       // mise à jour automatique (5 s)
      await edu.click("#inst-save"); await attendreTexte(edu, "#inst-msg", "modifiée par quelqu'un d'autre");
      await edu.click("#inst-discard");
      const lab = await edu.getAttribute('[data-g="0"][data-t="1"]', "aria-label");
      check(lab.includes("Massage 4") && lab.includes("à choisir 4"), "les 4 de Boccia sont « à choisir » : " + lab);
      check(!(await edu.$('[data-g="0"][data-t="5"]')), "T5 a disparu");
    });

    await etape("PDF : verrouille le planning ; l'organisatrice le déverrouille", async () => {
      await edu.click("#inst-pdf");
      await Promise.all([edu.waitForEvent("download"), edu.click("#inst-pdf")]);
      await edu.waitForSelector("#inst-lock:not([hidden])");
      await orga.click('[data-adm-j="couvin-2027"]'); await orga.waitForSelector("[data-inst-unlock]");
      await orga.click("[data-inst-unlock]"); await admMsg("déverrouillé");
      await edu.waitForSelector("#inst-lock", { state: "hidden", timeout: 15000 });
    });

    await etape("Organisatrice : corriger les coordonnées de l'institution", async () => {
      await orga.click("[data-inst-edit]"); await orga.fill("#ie-mail", "pas-un-mail"); await orga.click("[data-inst-form] [type=submit]");
      await admMsg("e-mail invalide");
      await orga.fill("#ie-mail", "direction@tilleuls.be"); await orga.click("[data-inst-form] [type=submit]"); await admMsg("Institution modifiée");
      check((await texte(orga, "#adm-insts")).includes("direction@tilleuls.be"), "nouvel e-mail affiché");
    });

    await etape("Dupliquer, puis supprimer (refusé tant qu'il y a une institution)", async () => {
      await orga.fill("#dup-nom", "Journée APA de Couvin 2028"); await orga.fill("#dup-date", "2028-06-08"); await orga.fill("#dup-id", "couvin-2028");
      await orga.click("#dup-save"); await admMsg("Copie créée");
      check((await orga.$$('#adm-ateliers tr[data-at]:not(.new)')).length === 3, "3 ateliers copiés");
      await orga.click('[data-adm-j="couvin-2027"]'); await orga.waitForSelector("#del-j");
      await two("#del-j"); await admMsg("encore 1 institution(s)");
      await two("[data-inst-del]"); await admMsg("supprimée avec ses participants");
      await two("#del-j"); await admMsg("(modifiée) » supprimée.");
      check(!(await orga.$('[data-adm-j="couvin-2027"]')), "Couvin 2027 a disparu de la liste");
    });

    await etape("Cacher la copie : elle disparaît du menu public", async () => {
      await orga.click('[data-adm-j="couvin-2028"]'); await orga.waitForSelector("#ji-visible");
      await orga.uncheck("#ji-visible"); await orga.click("#ji-save"); await admMsg("Informations enregistrées");
      await edu.goto(URL); await edu.waitForSelector(".event");
      check(!(await texte(edu, "#events")).includes("Couvin"), "plus de Couvin dans le menu");
    });

    await etape("Changer le code organisateur : l'ancien ne marche plus", async () => {
      await orga.click("#adm-pwd"); await orga.fill("#ac-old", ADMIN); await orga.fill("#ac-new", "nouveau-code-orga-1"); await orga.fill("#ac-new2", "nouveau-code-orga-2");
      await orga.click("#ac-save"); await admMsg("pas identiques");
      await orga.fill("#ac-new2", "nouveau-code-orga-1"); await orga.click("#ac-save"); await admMsg("Code organisateur changé");
      await orga.click("#adm-logout"); await orga.fill("#adm-code", ADMIN); await orga.click("#adm-login-btn");
      await attendreTexte(orga, "#adm-login-msg", "incorrect");
      await orga.fill("#adm-code", "nouveau-code-orga-1"); await orga.click("#adm-login-btn"); await orga.waitForSelector("#adm-app:not([hidden])");
    });

    await etape("Lisibilité de l'espace organisateur (contraste) en sombre et en clair, et sur téléphone", async () => {
      for (const scheme of ["dark", "light"]) {
        const p = await (await browser.newContext({ ...opts, colorScheme: scheme })).newPage(); pages.push(p);
        await p.goto(URL + "#organisateur"); await p.fill("#adm-code", "nouveau-code-orga-1"); await p.click("#adm-login-btn");
        await p.waitForSelector("#adm-info");
        const pb = await p.evaluate(AUDIT); check(!pb.length, `${scheme} : ${pb.join(" ; ")}`);
        await p.click("#adm-new"); const pb2 = await p.evaluate(AUDIT); check(!pb2.length, `${scheme}, nouvelle journée : ${pb2.join(" ; ")}`);
        await p.setViewportSize({ width: 390, height: 800 }); await p.click(".adm-j");
        check(!(await p.evaluate(() => document.documentElement.scrollWidth > innerWidth)), `${scheme} : pas de défilement horizontal sur téléphone`);
      }
    });

    check(!erreurs.length, "aucune erreur JavaScript : " + erreurs.join(" | "));
    console.log(`\n${n} étapes réussies, ${ok} vérifications, aucune erreur JavaScript.`);
    await browser.close(); process.exit(0);
  } catch (e) {
    console.log(`\nÉchec à l'étape ${n}. Captures dans tests/e2e/resultats/.`);
    if (erreurs.length) console.log("Erreurs JavaScript : " + erreurs.join(" | "));
    await browser.close(); process.exit(1);
  }
})();
