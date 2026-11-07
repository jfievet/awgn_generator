#include "bm_config.h"
#include "statistics.h"
#include "box_muller.h"
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <ctype.h>

static int qualify(void)
{
    bm_statistics s;
    if (!bm_qualify(BM_PRNG_SEED, BM_TEST_SAMPLES, &s)) {
        fputs("Qualification failed: invalid seed/count.\n", stderr);
        return EXIT_FAILURE;
    }
    bm_print_statistics(stdout, &s);
    return EXIT_SUCCESS;
}

static void export_samples(void)
{
    char line[128], *p;
    uint64_t count = 0, written = 0;
    bm_prng state;
    FILE *file;
    int failed = 0;
    fputs("Number of samples to export (samples_raw.txt will be replaced): ", stdout);
    fflush(stdout);
    if (!fgets(line, sizeof line, stdin)) return;
    if (!strchr(line, '\n') && !feof(stdin)) {
        int ch;
        while ((ch = getchar()) != '\n' && ch != EOF) { }
        puts("Invalid sample count."); return;
    }
    p = line;
    while (isspace((unsigned char)*p)) ++p;
    if (*p < '0' || *p > '9') { puts("Invalid sample count."); return; }
    while (*p >= '0' && *p <= '9') {
        unsigned digit = (unsigned)(*p-'0');
        if (count > (UINT64_MAX-digit)/10) { puts("Invalid sample count."); return; }
        count = count*10+digit;
        ++p;
    }
    while (isspace((unsigned char)*p)) ++p;
    if (*p || !count) { puts("Invalid sample count."); return; }
    if (!bm_prng_init(&state, BM_PRNG_SEED)) {
        fputs("Export failed: invalid PRNG seed.\n", stderr); return;
    }
    file = fopen("samples_raw.txt", "w");
    if (!file) { perror("Cannot open samples_raw.txt"); return; }
    while (written < count) {
        bm_trace t;
        bm_generate(&state, &t);
        if (fprintf(file, "%" PRId64 "\n", t.z0) < 0) { failed = 1; break; }
        ++written;
        if (written < count) {
            if (fprintf(file, "%" PRId64 "\n", t.z1) < 0) { failed = 1; break; }
            ++written;
        }
    }
    if (failed) perror("Cannot write samples_raw.txt");
    if (fclose(file) != 0) { perror("Cannot close samples_raw.txt"); failed = 1; }
    if (failed) fputs("Export failed: samples_raw.txt may be incomplete.\n", stderr);
    else printf("Exported %" PRIu64 " samples to samples_raw.txt\n", written);
}

int main(int argc, char **argv)
{
    char line[128];
    if (argc == 2) {
        if (!strcmp(argv[1], "--qualify")) return qualify();
        if (!strcmp(argv[1], "--config")) { bm_print_configuration(stdout); return EXIT_SUCCESS; }
        if (!strcmp(argv[1], "--samples")) { bm_print_samples(stdout, BM_PRNG_SEED); return EXIT_SUCCESS; }
    }
    if (argc != 1) { fputs("Usage: box_muller [--qualify|--config|--samples]\n", stderr); return EXIT_FAILURE; }
    puts("========================================\n FIXED-POINT BOX-MULLER GENERATOR\n========================================");
    bm_print_configuration(stdout);
    for (;;) {
        char *end;
        long option;
        puts("\n1 - Statistical qualification\n2 - Display current configuration\n3 - Generate and display 20 sample pairs\n4 - Export raw samples to samples_raw.txt\n0 - Exit");
        fputs("Select: ", stdout); fflush(stdout);
        if (!fgets(line, sizeof line, stdin)) return ferror(stdin) ? EXIT_FAILURE : EXIT_SUCCESS;
        if (!strchr(line, '\n') && !feof(stdin)) {
            int ch;
            while ((ch = getchar()) != '\n' && ch != EOF) { }
            puts("Invalid selection."); continue;
        }
        errno = 0;
        option = strtol(line, &end, 10);
        if (end == line) { puts("Invalid selection."); continue; }
        while (isspace((unsigned char)*end)) ++end;
        if (errno || *end || option < 0 || option > 4) { puts("Invalid selection."); continue; }
        switch (option) {
        case 0: return EXIT_SUCCESS;
        case 1: if (qualify()) return EXIT_FAILURE; break;
        case 2: bm_print_configuration(stdout); break;
        case 3: bm_print_samples(stdout, BM_PRNG_SEED); break;
        case 4: export_samples(); break;
        }
    }
}
