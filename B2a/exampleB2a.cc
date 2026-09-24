//
// ********************************************************************
// * License and Disclaimer                                           *
// *                                                                  *
// * The  Geant4 software  is  copyright of the Copyright Holders  of *
// * the Geant4 Collaboration.  It is provided  under  the terms  and *
// * conditions of the Geant4 Software License,  included in the file *
// * LICENSE and available at  http://cern.ch/geant4/license .  These *
// * include a list of copyright holders.                             *
// *                                                                  *
// * Neither the authors of this software system, nor their employing *
// * institutes,nor the agencies providing financial support for this *
// * work  make  any representation or  warranty, express or implied, *
// * regarding  this  software system or assume any liability for its *
// * use.  Please see the license in the file  LICENSE  and URL above *
// * for the full disclaimer and the limitation of liability.         *
// *                                                                  *
// * This  code  implementation is the result of  the  scientific and *
// * technical work of the GEANT4 collaboration.                      *
// * By using,  copying,  modifying or  distributing the software (or *
// * any work based  on the software)  you  agree  to acknowledge its *
// * use  in  resulting  scientific  publications,  and indicate your *
// * acceptance of all terms of the Geant4 Software license.          *
// ********************************************************************
//
/// \file exampleB2a.cc
/// \brief Main program of the B2/B2a example

#include "ActionInitialization.hh"
#include "DetectorConstruction.hh"

#include "G4EmStandardPhysics.hh"
#include "G4RunManagerFactory.hh"
#include "G4ScoringManager.hh"
#include "G4StepLimiterPhysics.hh"
#include "G4SteppingVerbose.hh"
#include "G4SystemOfUnits.hh"
#include "G4UIExecutive.hh"
#include "G4UImanager.hh"
#include "G4VModularPhysicsList.hh"
#include "G4VisExecutive.hh"
// #include "Randomize.hh"

#include <cstdlib>
#include <filesystem>

//....oooOO0OOooo........oooOO0OOooo........oooOO0OOooo........oooOO0OOooo......

int main(int argc, char** argv)
{
  // Usage: exampleB2a [-g geometry.gdml] [macro]
  // Without a macro the interactive (Qt) session starts.
  G4String gdmlFile, macro;
  for (G4int i = 1; i < argc; ++i) {
    G4String arg = argv[i];
    if (arg == "-g" && i + 1 < argc)
      gdmlFile = argv[++i];
    else
      macro = arg;
  }

  // Portable .app: datasets and macros live in <bundle>/Contents/Resources.
  // argv[0] is absolute for Finder and run.command launches; a launch through
  // a PATH lookup would need _NSGetExecutablePath instead.
  const auto resources =
    std::filesystem::weakly_canonical(std::filesystem::absolute(argv[0])).parent_path().parent_path()
    / "Resources";
  if (std::filesystem::is_directory(resources / "data")) {
    setenv("GEANT4_DATA_DIR", (resources / "data").c_str(), 0);  // a user-set value wins
  }

  // Detect interactive mode (if no macro) and define UI session
  //
  G4UIExecutive* ui = nullptr;
  if (macro.empty()) {
    ui = new G4UIExecutive(argc, argv);
  }

  // Optionally: choose a different Random engine...
  // G4Random::setTheEngine(new CLHEP::MTwistEngine);

  // use G4SteppingVerboseWithUnits
  G4int precision = 4;
  G4SteppingVerbose::UseBestUnit(precision);

  // Construct the default run manager
  //
  auto runManager = G4RunManagerFactory::CreateRunManager(G4RunManagerType::Default);

  // Enable command-based scoring (/score/...)
  G4ScoringManager::GetScoringManager();

  // Set mandatory initialization classes
  //
  runManager->SetUserInitialization(new B2a::DetectorConstruction(gdmlFile));

  // EM-only physics: the same option-0 EM constructor and 0.7 mm production cut
  // as FTFP_BERT, without its hadronic, decay and extra (gamma-nuclear) parts.
  auto physicsList = new G4VModularPhysicsList;
  physicsList->SetDefaultCutValue(0.7 * mm);
  physicsList->RegisterPhysics(new G4EmStandardPhysics());
  physicsList->RegisterPhysics(new G4StepLimiterPhysics());
  runManager->SetUserInitialization(physicsList);

  // Set user action classes
  runManager->SetUserInitialization(new B2::ActionInitialization());

  // Initialize visualization with the default graphics system
  auto visManager = new G4VisExecutive(argc, argv);
  // Constructors can also take optional arguments:
  // - a graphics system of choice, eg. "OGL"
  // - and a verbosity argument - see /vis/verbose guidance.
  // auto visManager = new G4VisExecutive(argc, argv, "OGL", "Quiet");
  // auto visManager = new G4VisExecutive("Quiet");
  visManager->Initialize();

  // Get the pointer to the User Interface manager
  auto UImanager = G4UImanager::GetUIpointer();

  // Look for macros in the current directory first, then in the bundle
  UImanager->ApplyCommand("/control/macroPath .:" + resources.string());

  // Process macro or start UI session
  //
  if (!ui) {
    // batch mode
    UImanager->ApplyCommand("/control/execute " + macro);
  }
  else {
    // interactive mode
    UImanager->ApplyCommand("/control/execute init_vis.mac");
    if (ui->IsGUI()) {
      UImanager->ApplyCommand("/control/execute gui.mac");
    }
    ui->SessionStart();
    delete ui;
  }

  // Job termination
  // Free the store: user actions, physics_list and detector_description are
  // owned and deleted by the run manager, so they should not be deleted
  // in the main() program !
  //
  delete visManager;
  delete runManager;
}

//....oooOO0OOooo........oooOO0OOooo........oooOO0OOooo........oooOO0OOooo.....
