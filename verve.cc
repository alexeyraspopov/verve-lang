#include <cassert>
#include <cstdio>
#include <fstream>
#include <libgen.h>

#include "parser/lexer.h"
#include "parser/parser.h"
#include "bytecode/generator.h"
#include "bytecode/disassembler.h"
#include "runtime/vm.h"

int main(int argc, char **argv) {
  char *first = argv[1];
  bool isDebug = strcmp(first, "-d") == 0;
  bool isCompile = strcmp(first, "-c") == 0;

  if (isCompile) {
    assert(argc == 4);
  } else if (isDebug) {
    assert(argc == 3);
  } else {
    assert(argc == 2);
  }

  auto filename = isDebug || isCompile ? argv[2] : argv[1];

  FILE *prelude = fopen("runtime/builtins.v", "r");
  FILE *source = fopen(filename, "r");
  fseek(prelude, 0, SEEK_END);
  fseek(source, 0, SEEK_END);
  size_t preludeSize = ftell(prelude);
  size_t sourceSize = ftell(source);
  fseek(prelude, 0, SEEK_SET);
  fseek(source, 0, SEEK_SET);

  char *input = (char *)malloc(preludeSize + sourceSize + 2);
  fread(input, 1, preludeSize, prelude);
  input[preludeSize] = '\n';
  fread(input + preludeSize + 1, 1, sourceSize, source);
  input[preludeSize + sourceSize + 1] = '\0';

  fclose(prelude);
  fclose(source);

  Verve::Lexer lexer(input, preludeSize + 1);

  char *dir = dirname(filename);

  Verve::Parser parser(lexer, dir);

  std::shared_ptr<Verve::AST::Program> ast = parser.parse();

  free(input);

  Verve::Generator generator(ast, isDebug);

  std::stringstream &bytecode = generator.generate();

  if (isDebug) {
    Verve::Disassembler disassembler(std::move(bytecode));
    disassembler.dump();
  } else if (isCompile) {
    std::ofstream output(argv[3], std::ios_base::binary);
    output << bytecode.str();
  } else {
    Verve::VM vm(bytecode);
    vm.execute();
  }

  return EXIT_SUCCESS;
}