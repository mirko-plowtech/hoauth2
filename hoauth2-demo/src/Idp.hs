{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

module Idp where

import Control.Monad.IO.Class
import Control.Monad.Trans.Except
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.Key as Aeson
import qualified Data.Aeson.KeyMap as Aeson
import Data.Bifunctor
import qualified Data.ByteString as BS
import Data.ByteString.Contrib
import Data.Default
import qualified Data.Map.Strict as Map
import Data.Maybe
import qualified Data.Set as Set
import Data.Text.Lazy (Text)
import qualified Data.Text.Lazy as TL
import qualified Data.Text.Lazy.Encoding  as TL
import qualified Env
import Jose.Jwt
import Lens.Micro
import Network.OAuth.OAuth2
import Network.OAuth2.Experiment
import qualified Network.OAuth2.Provider.Auth0 as IAuth0
import qualified Network.OAuth2.Provider.AzureAD as IAzureAD
import qualified Network.OAuth2.Provider.Dropbox as IDropbox
import qualified Network.OAuth2.Provider.Facebook as IFacebook
import qualified Network.OAuth2.Provider.Fitbit as IFitbit
import qualified Network.OAuth2.Provider.Github as IGithub
import qualified Network.OAuth2.Provider.Google as IGoogle
import qualified Network.OAuth2.Provider.Linkedin as ILinkedin
import qualified Network.OAuth2.Provider.Okta as IOkta
import qualified Network.OAuth2.Provider.Slack as ISlack
import qualified Network.OAuth2.Provider.StackExchange as IStackExchange
import qualified Network.OAuth2.Provider.Twitter as ITwitter
import qualified Network.OAuth2.Provider.Weibo as IWeibo
import qualified Network.OAuth2.Provider.ZOHO as IZOHO
import Session
import System.Directory
import Types
import URI.ByteString
import URI.ByteString.QQ (uri)
import Prelude hiding (id)

defaultOAuth2RedirectUri :: URI
defaultOAuth2RedirectUri = [uri|http://localhost:9988/oauth2/callback|]

createAuthorizationApps :: MonadIO m => (Idp IAuth0.Auth0, Idp IOkta.Okta) -> ExceptT Text m [DemoAuthorizationApp]
createAuthorizationApps (myAuth0Idp, myOktaIdp) = do
  configParams <- readEnvFile
  let initIdpAppConfig :: IdpApplication 'AuthorizationCode i -> IdpApplication 'AuthorizationCode i
      initIdpAppConfig idpAppConfig@AuthorizationCodeIdpApplication {..} =
        case Aeson.lookup (Aeson.fromString $ TL.unpack $ TL.toLower $ getIdpAppName idpAppConfig) configParams of
          Nothing -> idpAppConfig
          Just config ->
            idpAppConfig
              { idpAppClientId = ClientId $ Env.clientId config
              , idpAppClientSecret = ClientSecret $ Env.clientSecret config
              , idpAppRedirectUri = defaultOAuth2RedirectUri
              , idpAppScope = Set.unions [idpAppScope, Set.map Scope (Set.fromList (fromMaybe [] (Env.scopes config)))]
              , idpAppAuthorizeState = AuthorizeState (idpAppName <> ".hoauth2-demo-app-123")
              }
  pure
    [ DemoAuthorizationApp (initIdpAppConfig IAzureAD.defaultAzureADApp)
    , DemoAuthorizationApp (initIdpAppConfig (IAuth0.defaultAuth0App myAuth0Idp))
    , DemoAuthorizationApp (initIdpAppConfig IFacebook.defaultFacebookApp)
    , DemoAuthorizationApp (initIdpAppConfig IFitbit.defaultFitbitApp)
    , DemoAuthorizationApp (initIdpAppConfig IGithub.defaultGithubApp)
    , DemoAuthorizationApp (initIdpAppConfig IDropbox.defaultDropboxApp)
    , DemoAuthorizationApp (initIdpAppConfig IGoogle.defaultGoogleApp)
    , DemoAuthorizationApp (initIdpAppConfig ILinkedin.defaultLinkedinApp)
    , DemoAuthorizationApp (initIdpAppConfig (IOkta.defaultOktaApp myOktaIdp))
    , DemoAuthorizationApp (initIdpAppConfig ITwitter.defaultTwitterApp)
    , DemoAuthorizationApp (initIdpAppConfig ISlack.defaultSlackApp)
    , DemoAuthorizationApp (initIdpAppConfig IWeibo.defaultWeiboApp)
    , DemoAuthorizationApp (initIdpAppConfig IZOHO.defaultZohoApp)
    , DemoAuthorizationApp (initIdpAppConfig IStackExchange.defaultStackExchangeApp)
    ]

googleServiceAccountApp ::
  ExceptT
    Text
    IO
    (IdpApplication 'JwtBearer IGoogle.Google)
googleServiceAccountApp = do
  IGoogle.GoogleServiceAccountKey {..} <- withExceptT TL.pack (ExceptT $ Aeson.eitherDecodeFileStrict ".google-sa.json")
  pkey <- withExceptT TL.pack (ExceptT $ IGoogle.readPemRsaKey privateKey)
  jwt <-
    withExceptT
      TL.pack
      ( ExceptT $
          IGoogle.mkJwt
            pkey
            clientEmail
            Nothing
            ( Set.fromList
                [ "https://www.googleapis.com/auth/userinfo.email"
                , "https://www.googleapis.com/auth/userinfo.profile"
                ]
            )
            IGoogle.defaultGoogleIdp
      )
  pure $ IGoogle.defaultServiceAccountApp jwt

oktaPasswordGrantApp :: Idp IOkta.Okta -> IdpApplication 'ResourceOwnerPassword IOkta.Okta
oktaPasswordGrantApp i =
  ResourceOwnerPasswordIDPApplication
    { idpAppClientId = ""
    , idpAppClientSecret = ""
    , idpAppName = "okta-demo-password-grant-app"
    , idpAppScope = Set.fromList ["openid", "profile"]
    , idpAppUserName = ""
    , idpAppPassword = ""
    , idpAppTokenRequestExtraParams = Map.empty
    , idp = i
    }

-- Base on the document, it works well with custom Athourization Server
-- https://developer.okta.com/docs/guides/implement-grant-type/clientcreds/main/#client-credentials-flow
--
-- With Org AS, got this error
-- Client Credentials requests to the Org Authorization Server must use the private_key_jwt token_endpoint_auth_method
--
oktaClientCredentialsGrantApp :: Idp IOkta.Okta -> IO (IdpApplication 'ClientCredentials IOkta.Okta)
oktaClientCredentialsGrantApp i = do
  let clientId = "0oa9mbklxn2Ac0oJ24x7"
  keyJsonStr <- BS.readFile ".okta-key.json"
  case Aeson.eitherDecodeStrict keyJsonStr of
    Right jwk -> do
      ejwt <- IOkta.mkOktaClientCredentialAppJwt jwk clientId i
      case ejwt of
        Right jwt ->
          pure
            ClientCredentialsIDPApplication
              { idpAppClientId = clientId
              , idpAppClientSecret = ClientSecret (TL.decodeUtf8 $ bsFromStrict $ unJwt jwt)
              , idpAppTokenRequestAuthenticationMethod = ClientAssertionJwt
              , idpAppName = "okta-demo-cc-grant-jwt-app"
              , -- , idpAppScope = Set.fromList ["hw-test"]
                idpAppScope = Set.fromList ["okta.users.read"]
              , idpAppTokenRequestExtraParams = Map.empty
              , idp = i
              }
        Left e -> Prelude.error e
    Left e -> Prelude.error e

-- | https://auth0.com/docs/api/authentication#resource-owner-password
auth0PasswordGrantApp :: Idp IAuth0.Auth0 -> IdpApplication 'ResourceOwnerPassword IAuth0.Auth0
auth0PasswordGrantApp i =
  ResourceOwnerPasswordIDPApplication
    { idpAppClientId = ""
    , idpAppClientSecret = ""
    , idpAppName = "auth0-demo-password-grant-app"
    , idpAppScope = Set.fromList ["openid", "profile", "email"]
    , idpAppUserName = "test"
    , idpAppPassword = ""
    , idpAppTokenRequestExtraParams = Map.empty
    , idp = i
    }

-- | https://auth0.com/docs/api/authentication#client-credentials-flow
auth0ClientCredentialsGrantApp :: Idp IAuth0.Auth0 -> IdpApplication 'ClientCredentials IAuth0.Auth0
auth0ClientCredentialsGrantApp i =
  ClientCredentialsIDPApplication
    { idpAppClientId = ""
    , idpAppClientSecret = ""
    , idpAppTokenRequestAuthenticationMethod = ClientSecretPost
    , idpAppName = "auth0-demo-cc-grant-app"
    , idpAppScope = Set.fromList ["read:users"]
    , idpAppTokenRequestExtraParams = Map.fromList [("audience ", "https://freizl.auth0.com/api/v2/")]
    , idp = i
    }

isSupportPkce :: forall a i. ('AuthorizationCode ~ a) => IdpApplication a i -> Bool
isSupportPkce AuthorizationCodeIdpApplication {..} =
  let hostStr = idpAuthorizeEndpoint idp ^. (authorityL . _Just . authorityHostL . hostBSL)
   in any
        (`BS.isInfixOf` hostStr)
        [ "auth0.com"
        , "okta.com"
        , "google.com"
        , "twitter.com"
        ]

envFilePath :: String
envFilePath = ".env.json"

readEnvFile :: MonadIO m => ExceptT Text m Env.EnvConfig
readEnvFile = liftIO $ do
  pwd <- getCurrentDirectory
  envFileE <- doesFileExist (pwd <> "/" <> envFilePath)
  if envFileE
    then do
      putStrLn "Found .env.json"
      fileContent <- BS.readFile envFilePath
      case Aeson.eitherDecodeStrict fileContent of
        Left err -> print err >> return Aeson.empty
        Right ec -> return ec
    else return Aeson.empty

initIdps :: MonadIO m => CacheStore -> (Idp IAuth0.Auth0, Idp IOkta.Okta) -> ExceptT Text m ()
initIdps c is = do
  idps <- createAuthorizationApps is
  mapM mkDemoAppEnv idps >>= mapM_ (upsertDemoAppEnv c)

mkDemoAppEnv :: MonadIO m => DemoAuthorizationApp -> ExceptT Text m DemoAppEnv
mkDemoAppEnv ia@(DemoAuthorizationApp idpAppConfig) = do
  re <-
    if isSupportPkce idpAppConfig
      then fmap (second Just) (mkPkceAuthorizeRequest idpAppConfig)
      else pure (mkAuthorizeRequest idpAppConfig, Nothing)
  pure $ DemoAppEnv ia (def {authorizeAbsUri = fst re, authorizePkceCodeVerifier = snd re})
