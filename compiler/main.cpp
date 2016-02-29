#include <cassert>
#include <cstdio>
#include <fstream>

#include "./lexer.h"
#include "./parser.h"
#include "./generator.h"

int main(int argc, char **argv) {
  assert(argc == 3);

  std::ifstream input(argv[1]);
  std::ofstream output(argv[2]);

  ceos::Lexer lexer(input);
  ceos::Parser parser(lexer);

  ceos::AST::Program ast = parser.parse();

  ceos::Generator generator(ast, output);

  if (generator.generate()) {
    return EXIT_SUCCESS;
  } else {
    return EXIT_FAILURE;
  }
}
