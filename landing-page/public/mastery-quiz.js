// Wires up <section class="mastery-quiz" data-lesson="..."> blocks.
//
// Each lesson page contains at most one quiz section. Each .mc-item
// carries a data-correct attribute (the index of the correct option).
// On submit:
//   * compute the score
//   * mark each item .is-correct or .is-wrong
//   * highlight the correct option per item
//   * lock all radios so the answers don't change post-submission
// Reset clears state and unlocks the inputs.

(() => {
    const quizzes = document.querySelectorAll('.mastery-quiz');
    if (quizzes.length === 0) return;

    for (const quiz of quizzes) {
        const items = [...quiz.querySelectorAll('.mc-item')];
        const submit = quiz.querySelector('.mc-submit');
        const reset = quiz.querySelector('.mc-reset');
        const scoreEl = quiz.querySelector('.mc-score');
        if (!submit || !reset || !scoreEl || items.length === 0) continue;

        submit.addEventListener('click', () => {
            let correct = 0;
            for (const item of items) {
                const want = Number(item.getAttribute('data-correct'));
                const radios = [...item.querySelectorAll('input[type="radio"]')];
                const picked = radios.find((r) => r.checked);
                const got = picked ? Number(picked.value) : null;
                const ok = got === want;
                if (ok) correct++;

                item.classList.toggle('is-correct', ok);
                item.classList.toggle('is-wrong', !ok);

                const feedback = item.querySelector('.mc-feedback');
                if (feedback) {
                    feedback.hidden = false;
                    feedback.textContent = ok
                        ? 'Correct.'
                        : picked
                            ? 'Not quite — see the highlighted answer above.'
                            : 'No answer — see the highlighted answer above.';
                }

                const options = item.querySelectorAll('.mc-options li');
                options.forEach((li, idx) => {
                    li.classList.toggle('is-answer', idx === want);
                    li.classList.toggle('is-picked', got !== null && idx === got);
                    const expl = li.querySelector('.mc-explanation');
                    if (expl) expl.hidden = false;
                });

                for (const r of radios) r.disabled = true;
            }

            const total = items.length;
            const pct = Math.round((correct / total) * 100);
            scoreEl.hidden = false;
            scoreEl.textContent = `Score: ${correct} / ${total}  (${pct}%)`;

            submit.hidden = true;
            reset.hidden = false;
        });

        reset.addEventListener('click', () => {
            for (const item of items) {
                item.classList.remove('is-correct', 'is-wrong');
                const feedback = item.querySelector('.mc-feedback');
                if (feedback) {
                    feedback.hidden = true;
                    feedback.textContent = '';
                }
                const options = item.querySelectorAll('.mc-options li');
                options.forEach((li) => {
                    li.classList.remove('is-answer', 'is-picked');
                    const expl = li.querySelector('.mc-explanation');
                    if (expl) expl.hidden = true;
                });
                for (const r of item.querySelectorAll('input[type="radio"]')) {
                    r.disabled = false;
                    r.checked = false;
                }
            }
            scoreEl.hidden = true;
            scoreEl.textContent = '';
            submit.hidden = false;
            reset.hidden = true;
        });
    }
})();
